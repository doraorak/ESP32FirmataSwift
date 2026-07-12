// IR module (id 0x01): NEC/RC6/raw transmit and NEC receive over the RMT peripheral.

/* ==== IR module (NEC over RMT) — a ModuleHandler ==========================
   A `ModuleHandler` class (see Modules.swift): the module subsystem owns one instance,
   routes MODULE_DATA(0x0D)/MODULE_OP(0x33) payloads for id 0x01 to `handle`, and calls
   `tick` each main-loop iteration. Ops:
     0x00 <pin>              configure the TX pin (carrier is per-send)
     0x02 <pin> <dstReg> [<protocol>]  start RX; each decoded frame → R[dstReg], event 0x03.
                             protocol 0 = NEC (default, omitted byte = old wire form),
                             1 = RC6 mode 0, 2 = Coolix (Midea AC family, 24-bit).
                             All decode the SAME raw RMT capture the sniffer sees.
     0x03 <kHz> <durations>  raw send (host-encoded NEC/RC6/any protocol)
     0x04 …                  repeat/hold send (frame A / optional toggle frame B)
     0x05 <protocol> <srcReg> encode a code held in a register on-device (NEC/RC6) and send
     0x06 <pin> <enable>     raw capture: push EVERY received burst as event 0x07
                             <totalLo> <totalHi> <durations, 14-bit LE pairs> — protocol
                             sniffing for remotes the NEC decoder can't read (AC units etc.)
     0x08 <pin> <slot>       receive raw timings as the TEXT "[d0,d1,…]" into device string
                             <slot> — printable on the OLED / inspectable to learn a protocol */
final class IRModuleHandler: ModuleHandler {
  let id: UInt8 = 0x01
  let major: UInt8 = 1
  let minor: UInt8 = 3
  let name: StaticString = "ir"

  var txPin: Int32 = -1
  var rxPin: Int32 = -1
  var dstReg = 0
  var rxProtocol: UInt8 = 0                         // 0 NEC, 1 RC6, 2 Coolix
  var rawTextSlot: Int = -1                        // op 0x08: format each burst as text into this slot
  var rawReport = false                             // op 0x06: mirror captures to the host
  var rxBuf = [Int32](repeating: 0, count: 256)    // reused; no per-tick allocation
  var rawBuf = [Int32](repeating: 0, count: 224)   // staged send durations — sized for a
                                                    // doubled Coolix message (199)
  var txCount = 0                                   // total durations staged (frame A, then optional B)
  var txNA = 0                                      // durations in frame A; B = [txNA..<txCount]
  var txSendIdx = 0                                 // send # in a repeat run (even=A, odd=B: RC6 toggle)
  var txRepeatLeft = 0                              // pending re-sends for a repeat (op 0x04)
  var txGapMs: UInt32 = 0                           // gap between repeated presses
  var txNextMs: UInt32 = 0                          // when the next repeated press is due

  #if IR_DEBUG
  // Bring-up capture ring exposed via debug ops 0x7C-0x7E. Compiled out unless -D IR_DEBUG.
  var lastCapture = [Int32](repeating: 0, count: 40)
  var lastCaptureCount = 0
  var captureTotal = 0
  #endif

  // Parse 14-bit LE duration pairs from payload[start...] into rawBuf.
  func stage(_ payload: [UInt8], _ length: Int, from start: Int) {
    var count = 0, index = start
    while index + 1 < length && count < rawBuf.count {
      rawBuf[count] = Int32(payload[index] & 0x7F) | (Int32(payload[index + 1] & 0x7F) << 7)
      count += 1; index += 2
    }
    txCount = count
  }

  // Transmit frame A (even index) or frame B (odd index, when a distinct B exists — the RC6 toggle
  // variant, so consecutive repeats read as separate presses). NEC/raw have no B → always A.
  func txFrame(_ sendIndex: Int) {
    if txCount <= 0 || txNA <= 0 { return }
    let hasFrameB = txCount > txNA
    let useFrameB = hasFrameB && (sendIndex & 1 == 1)
    let offset = useFrameB ? txNA : 0
    let count  = useFrameB ? txCount - txNA : txNA
    rawBuf.withUnsafeBufferPointer { fm_rmt_tx(txPin, $0.baseAddress! + offset, Int32(count)) }
  }

  // Non-blocking repeat: re-send (alternating A/B) every txGapMs until the count runs out.
  func txTick() {
    if txRepeatLeft > 0 && txPin >= 0 {
      let now = fm_millis()
      if now &- txNextMs < 0x8000_0000 {   // now >= txNextMs (unsigned wrap-safe)
        txFrame(txSendIdx)
        txSendIdx += 1
        txRepeatLeft -= 1
        txNextMs = now &+ txGapMs
      }
    }
  }

  /* On-device NEC/RC6 encoders (op 0x05). A code held in a register only exists at runtime on the
     board, so it can't be encoded on the host — these build the timing waveform here. Each fills
     rawBuf and returns the duration count. Mirrors SwiftFirmataIR's host-side necTiming/rc6Timing. */
  func encodeNEC(_ code: UInt32) -> Int {
    var count = 0
    func put(_ duration: Int32) { if count < rawBuf.count { rawBuf[count] = duration; count += 1 } }
    put(9000); put(4500)                                     // 9 ms / 4.5 ms header
    var bit = 31
    while bit >= 0 {
      put(562)
      put(((code >> UInt32(bit)) & 1) == 1 ? 1687 : 562)     // 1 = long space, 0 = short
      bit -= 1
    }
    put(562)                                                 // trailing mark
    return count
  }

  /// Coolix (Midea AC family), 38 kHz: 4692/4416 µs header, 552 µs marks, space 1656 = 1 /
  /// 552 = 0. The 24-bit code goes out as byte+complement pairs (48 wire bits), and the
  /// whole message is sent twice — real Coolix remotes always double it.
  func encodeCoolix(_ code: UInt32) -> Int {
    var count = 0
    func put(_ duration: Int32) { if count < rawBuf.count { rawBuf[count] = duration; count += 1 } }
    func section() {
      put(4692); put(4416)
      var byteIndex = 2
      while byteIndex >= 0 {
        let byte = (code >> UInt32(byteIndex * 8)) & 0xFF
        for value in [byte, ~byte & 0xFF] {
          var bit = 7
          while bit >= 0 {
            put(552)
            put(((value >> UInt32(bit)) & 1) == 1 ? 1656 : 552)
            bit -= 1
          }
        }
        byteIndex -= 1
      }
      put(552)                                              // footer mark
    }
    section(); put(5244); section()                         // message + gap + repeat
    return count
  }

  func encodeRC6(_ data: UInt32, bits: Int) -> Int {
    let t: Int32 = 444
    var count = 0
    // Append an event, merging consecutive same-level runs (rawBuf[even]=mark, [odd]=space).
    func emit(_ mark: Bool, _ duration: Int32) {
      let expectMark = (count % 2 == 0)
      if mark == expectMark { if count < rawBuf.count { rawBuf[count] = duration; count += 1 } }
      else if count > 0 { rawBuf[count - 1] += duration }
    }
    emit(true, 6 * t); emit(false, 2 * t)                    // leader
    emit(true, t);     emit(false, t)                        // start bit (always 1)
    var i = 1
    var mask: UInt32 = bits > 0 ? (UInt32(1) << (bits - 1)) : 0
    while mask != 0 {
      let bitWidth: Int32 = (i == 4) ? 2 * t : t             // 4th bit = double-width toggle
      if data & mask != 0 { emit(true, bitWidth); emit(false, bitWidth) }   // 1
      else                { emit(false, bitWidth); emit(true, bitWidth) }   // 0
      i += 1; mask >>= 1
    }
    return count
  }

  // SYSTEM_RESET forgets the receiver: `systemResetState()` reset every pin to input mode,
  // which detached the RMT receiver — so drop rxPin/rawTextSlot and let the next receive op
  // re-arm (the arm is pin-change-gated, so without this it would wrongly skip re-init).
  func reset() {
    rxPin = -1
    rawTextSlot = -1
    rawReport = false
  }

  func handle(_ payload: [UInt8], _ length: Int) {
    if length < 1 { return }
    switch payload[0] {
    case 0x00:
      // Configure the TX pin. The carrier is set per send by the raw op (0x03).
      if length >= 2 && fm_rmt_tx_init(Int32(payload[1] & 0x7F), 0) != 0 { txPin = Int32(payload[1] & 0x7F) }
    case 0x02:
      // Arm the receiver only when the pin actually changes — re-running this op (e.g. every
      // pass of a repeating task) then just updates the register/protocol without a re-init
      // that would drop a frame mid-capture.
      if length >= 3 {
        let pin = Int32(payload[1] & 0x7F)
        if rxPin != pin && fm_rmt_rx_init(pin) != 0 { rxPin = pin }
        if rxPin == pin {
          dstReg = Int(payload[2] & REG_MASK)
          rxProtocol = length >= 4 ? payload[3] & 0x7F : 0
        }
      }
    case 0x03:
      // Raw send: <carrierKHz> <duration pairs as 14-bit LE>. Marks HIGH; carrierKHz 0 = no
      // carrier. NEC, RC6, and any other protocol are encoded host-side and replayed here.
      if length >= 4 && txPin >= 0 {
        _ = fm_rmt_tx_carrier(txPin, 0, 33, Int32(payload[1] & 0x7F) * 1000)   // marks-high carrier (0 = off)
        txRepeatLeft = 0                                                       // cancel any pending repeat
        stage(payload, length, from: 2)
        txNA = txCount                                                         // one frame, no B
        txFrame(0)
      }
    case 0x04:
      // Repeat/hold send: <carrierKHz> <repeat> <gapLo> <gapHi> <nA_lo> <nA_hi> <A durs> <B durs>.
      // nA = durations in frame A; the rest are frame B (the RC6 toggle-flipped variant, so
      // repeats are distinct presses). No B (all durs in A) → every repeat sends A (NEC/raw).
      // Sends A now, then re-sends alternating A/B (repeat-1) more times, gapMs apart, via the tick.
      if length >= 8 && txPin >= 0 {
        _ = fm_rmt_tx_carrier(txPin, 0, 33, Int32(payload[1] & 0x7F) * 1000)
        let repeats = Int(payload[2] & 0x7F)
        txGapMs = UInt32(payload[3] & 0x7F) | (UInt32(payload[4] & 0x7F) << 7)
        let frameALength = Int(payload[5] & 0x7F) | (Int(payload[6] & 0x7F) << 7)
        stage(payload, length, from: 7)
        txNA = frameALength < txCount ? frameALength : txCount
        txFrame(0)
        txSendIdx = 1
        txRepeatLeft = repeats > 1 ? repeats - 1 : 0
        txNextMs = fm_millis() &+ txGapMs
      }
    case 0x05:
      // Encode + send a numeric code held in a register: <protocol> <srcReg>. protocol 0 = NEC
      // (38 kHz), 1 = RC6 (36 kHz), 2 = Coolix (38 kHz). Lets a task replay a received/computed
      // code the host can't pre-encode.
      if length >= 3 && txPin >= 0 {
        let proto = payload[1] & 0x7F
        let code = UInt32(bitPattern: scheduler.regs[Int(payload[2] & REG_MASK)])
        _ = fm_rmt_tx_carrier(txPin, 0, 33, (proto == 1 ? 36 : 38) * 1000)
        txRepeatLeft = 0
        if proto == 1 { txCount = encodeRC6(code, bits: 20) }
        else if proto == 2 { txCount = encodeCoolix(code) }
        else { txCount = encodeNEC(code) }
        txNA = txCount
        txFrame(0)
      }
    case 0x08:
      // Receive raw timings as TEXT into a device string slot: <pin> <slot>. Each burst is
      // formatted "[d0,d1,d2,…]" into the slot — printable on the OLED (displayPrint string)
      // or inspectable, so an unknown remote's protocol can be read off directly. Arm only on
      // a pin change so re-running the op each pass never resets a capture in progress.
      if length >= 3 {
        let pin = Int32(payload[1] & 0x7F)
        if rxPin != pin && fm_rmt_rx_init(pin) != 0 { rxPin = pin }
        if rxPin == pin { rawTextSlot = Int(payload[2] & 0x7F) }
      }
    case 0x06:
      // Raw capture on/off. Enabling (re)arms the receiver on <pin>; NEC decode keeps
      // running alongside, so a known remote still lands codes while sniffing.
      if length >= 3 {
        if payload[2] & 0x7F != 0 {
          if fm_rmt_rx_init(Int32(payload[1] & 0x7F)) != 0 {
            rxPin = Int32(payload[1] & 0x7F)
            rawReport = true
          }
        } else {
          rawReport = false
        }
      }
    #if IR_DEBUG
    case 0x7C:
      // Debug: invert the TX envelope. <invert 0/1> (0 = mark HIGH, 1 = mark LOW)
      if length >= 2 { fm_rmt_tx_set_invert(Int32(payload[1] & 0x01)) }
    case 0x7D:
      // Debug: retune the TX carrier live. <polarity 0/1> <dutyPercent 0..100> <freqKHz>
      if length >= 4 && txPin >= 0 {
        let polarity = Int32(payload[1] & 0x01)
        let duty = Int32(payload[2] & 0x7F)
        let freqHz = Int32(payload[3] & 0x7F) * 1000
        _ = fm_rmt_tx_carrier(txPin, polarity, duty, freqHz)
      }
    case 0x7E:
      // Debug: dump the last capture (count + durations as 14-bit LE pairs).
      var out: [UInt8] = [START_SYSEX, MODULE_DATA, id, 0x7E,
                          UInt8(captureTotal & 0x7F), UInt8(lastCaptureCount & 0x7F),
                          UInt8(truncatingIfNeeded: txPin + 1) & 0x7F,
                          UInt8(truncatingIfNeeded: rxPin + 1) & 0x7F,
                          UInt8(truncatingIfNeeded: fm_rmt_rx_status()) & 0x7F,
                          UInt8(truncatingIfNeeded: fm_rmt_tx_last() + 1) & 0x7F]
      var index = 0
      while index < lastCaptureCount {
        var duration = lastCapture[index]
        if duration < 0 { duration = 0 }
        if duration > 16383 { duration = 16383 }
        out.append(UInt8(duration & 0x7F))
        out.append(UInt8((duration >> 7) & 0x7F))
        index += 1
      }
      out.append(END_SYSEX)
      sendFrame(out, out.count)
    #endif
    default: break
    }
  }

  /* NEC decode with ±25% tolerance; level-agnostic (works with active-low TSOP
     receivers): only the duration SEQUENCE matters. */
  func near(_ value: Int32, _ target: Int32) -> Bool {
    value > target - target / 4 && value < target + target / 4
  }

  // Called every main-loop iteration: poll the receiver (decode NEC) and drive any repeat run.
  func tick() {
    txTick()
    if rxPin < 0 { return }
    let captureCount = rxBuf.withUnsafeMutableBufferPointer { fm_rmt_rx_poll($0.baseAddress, 256) }
    if rawReport && captureCount >= 6 {              // skip sub-3-symbol noise blips
      var out: [UInt8] = [START_SYSEX, MODULE_DATA, id, 0x07,
                          UInt8(Int(captureCount) & 0x7F), UInt8((Int(captureCount) >> 7) & 0x7F)]
      var index = 0
      while index < Int(captureCount) {
        var duration = rxBuf[index]
        if duration < 0 { duration = 0 }
        if duration > 16383 { duration = 16383 }
        out.append(UInt8(duration & 0x7F))
        out.append(UInt8((duration >> 7) & 0x7F))
        index += 1
      }
      out.append(END_SYSEX)
      sendFrame(out, out.count)
    }
    #if IR_DEBUG
    if captureCount > 0 {                            // stash every capture for the 0x7E dump
      captureTotal += 1
      lastCaptureCount = min(Int(captureCount), 40)
      for index in 0..<lastCaptureCount { lastCapture[index] = rxBuf[index] }
    }
    #endif
    // All protocols decode the same raw capture the sniffer sees (op 0x02's protocol byte
    // picks the decoder; a burst that doesn't parse is simply ignored).
    // Only format a REAL burst (poll returns 0 between frames — formatting those would
    // overwrite the capture with "[]" microseconds later).
    if rawTextSlot >= 0 && captureCount >= 6 { formatRawText(Int(captureCount)) }
    switch rxProtocol {
    case 1:  decodeRC6Capture(Int(captureCount))
    case 2:  decodeCoolixCapture(Int(captureCount))
    default: decodeNECCapture(Int(captureCount))
    }
  }

  /// Deliver a decoded frame: destination register + event 0x03 to the host.
  func emitReceived(_ code: UInt32) {
    scheduler.regs[dstReg] = Int32(bitPattern: code)
    var out: [UInt8] = [START_SYSEX, MODULE_DATA, id, 0x03]
    var remaining = code
    for _ in 0..<5 { out.append(UInt8(remaining & 0x7F)); remaining >>= 7 }
    out.append(END_SYSEX)
    sendFrame(out, out.count)
  }

  /// NEC: 9 ms / 4.5 ms header, then 32 bits of 562 µs mark + 562/1687 µs space.
  func decodeNECCapture(_ count: Int) {
    if count < 66 { return }
    var index = 0
    while index + 1 < count && !(near(rxBuf[index], 9000) && near(rxBuf[index + 1], 4500)) { index += 1 }
    if index + 66 > count { return }
    index += 2
    var code: UInt32 = 0
    var bitIndex = 0
    while bitIndex < 32 {
      let mark = rxBuf[index], space = rxBuf[index + 1]
      if !near(mark, 562) { return }
      if near(space, 1687) { code = (code << 1) | 1 }
      else if near(space, 562) { code = code << 1 }
      else { return }
      index += 2; bitIndex += 1
    }
    emitReceived(code)
  }

  /// Coolix: ~4.5/4.4 ms header, 552 µs marks, space 1656 = 1 / 552 = 0; 48 wire bits =
  /// three byte+complement pairs, folded to the 24-bit code after the complements check.
  /// Real remotes double the message; the first section in the capture is enough.
  func decodeCoolixCapture(_ count: Int) {
    if count < 98 { return }
    var index = 0
    while index + 1 < count && !(near(rxBuf[index], 4550) && near(rxBuf[index + 1], 4400)) { index += 1 }
    if index + 98 > count { return }
    index += 2
    var bits: UInt64 = 0
    var bitIndex = 0
    // Wide windows, split at 1 ms: real receivers stretch marks (up to ~750 µs seen) and
    // shrink zero-spaces (down to ~370 µs) — the two space clusters stay far apart.
    while bitIndex < 48 {
      let mark = rxBuf[index], space = rxBuf[index + 1]
      if mark < 350 || mark > 950 { return }
      if space > 1000 && space < 2400 { bits = (bits << 1) | 1 }
      else if space > 250 && space <= 1000 { bits = bits << 1 }
      else { return }
      index += 2; bitIndex += 1
    }
    var code: UInt32 = 0
    var byteIndex = 0
    while byteIndex < 3 {
      let byte = UInt32(truncatingIfNeeded: bits >> UInt64(40 - byteIndex * 16)) & 0xFF
      let complement = UInt32(truncatingIfNeeded: bits >> UInt64(32 - byteIndex * 16)) & 0xFF
      if complement != (~byte & 0xFF) { return }
      code = (code << 8) | byte
      byteIndex += 1
    }
    emitReceived(code)
  }

  /// Format a raw capture as the ASCII string "[d0,d1,d2,…]" into device string `rawTextSlot`.
  /// Capped at ~500 bytes (≈90 durations) — enough for a full NEC frame and the header + lead
  /// bits of longer AC frames, which is what fingerprints a protocol. Reuses `frameBuf` as scratch.
  func formatRawText(_ count: Int) {
    var out = 0
    func put(_ b: UInt8) { if out < 500 { frameBuf[out] = b; out += 1 } }
    func putNum(_ v: Int32) {
      if v == 0 { put(0x30); return }
      var digits = [UInt8](repeating: 0, count: 10)
      var n = 0, x = v < 0 ? 0 : v
      while x > 0 && n < 10 { digits[n] = UInt8(0x30 + Int(x % 10)); x /= 10; n += 1 }
      while n > 0 { n -= 1; put(digits[n]) }
    }
    put(0x5B)                                        // '['
    var i = 0
    while i < count && out < 495 {
      if i > 0 { put(0x2C) }                         // ','
      var d = rxBuf[i]
      if d < 0 { d = 0 }
      putNum(d)
      i += 1
    }
    put(0x5D)                                        // ']'
    _ = frameBuf.withUnsafeBufferPointer { fm_snapshot_copy(Int32(rawTextSlot), $0.baseAddress!, Int32(out)) }
  }

  /// RC6 mode 0: 6t/2t leader (t = 444 µs), a `1` start bit, then Manchester bits with the
  /// 4th one double-width (the toggle). Durations are converted to half-bit units and the
  /// unit stream is walked bit by bit; 16–32 decoded bits (incl. mode+toggle) = a frame —
  /// so a TV key arrives as e.g. 0x0000C or 0x1000C depending on the toggle.
  func decodeRC6Capture(_ count: Int) {
    let t: Int32 = 444
    // Flatten durations into a level-per-unit stream (true = mark). A duration that
    // doesn't round to 1..8 units ends the usable stream (idle gap / glitch).
    var unitLevel = [Bool](repeating: false, count: 200)
    var unitCount = 0
    var durIndex = 0
    while durIndex < count && unitCount < 200 {
      let duration = rxBuf[durIndex]
      let units = Int((duration + t / 2) / t)
      if units < 1 || units > 8 { break }
      let isMark = durIndex % 2 == 0
      var k = 0
      while k < units && unitCount < 200 { unitLevel[unitCount] = isMark; unitCount += 1; k += 1 }
      durIndex += 1
    }
    // Leader: 6 mark units + 2 space units; start bit: mark, space (= 1).
    if unitCount < 12 { return }
    var p = 0
    for _ in 0..<6 { if !unitLevel[p] { return }; p += 1 }
    for _ in 0..<2 { if unitLevel[p] { return }; p += 1 }
    if !(unitLevel[p] && !unitLevel[p + 1]) { return }
    p += 2
    // Manchester bits: first half mark = 1, space = 0; the 4th bit is double-width.
    var code: UInt32 = 0
    var bitsRead = 0
    while bitsRead < 32 {
      let width = (bitsRead == 3) ? 2 : 1
      if p + 2 * width > unitCount { break }
      var halvesValid = true
      for k in 1..<width where unitLevel[p + k] != unitLevel[p] { halvesValid = false }
      for k in 1..<width where unitLevel[p + width + k] != unitLevel[p + width] { halvesValid = false }
      if !halvesValid || unitLevel[p] == unitLevel[p + width] { break }
      code = (code << 1) | (unitLevel[p] ? 1 : 0)
      p += 2 * width
      bitsRead += 1
    }
    // A frame whose LAST bit is a 1 ends mark-then-space — that final space merges into
    // the idle gap and is never captured, leaving a lone trailing mark half-unit. Infer
    // the bit (vol-down 0x11 decoded as 0x8 without this; …0 frames end on a captured mark).
    if bitsRead < 32 && p < unitCount && unitLevel[p] {
      code = (code << 1) | 1
      bitsRead += 1
    }
    if bitsRead < 16 { return }
    emitReceived(code)
  }
}
