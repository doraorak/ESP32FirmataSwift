// IR module (id 0x01): NEC/RC6/raw transmit and NEC receive over the RMT peripheral.

/* ==== IR module (NEC over RMT) — a ModuleHandler ==========================
   A `ModuleHandler` class (see Modules.swift): the module subsystem owns one instance,
   routes MODULE_DATA(0x0D)/MODULE_OP(0x33) payloads for id 0x01 to `handle`, and calls
   `tick` each main-loop iteration. Ops:
     0x00 <pin>              configure the TX pin (carrier is per-send)
     0x02 <pin> <dstReg>     start RX; each decoded NEC frame → R[dstReg], event 0x03
     0x03 <kHz> <durations>  raw send (host-encoded NEC/RC6/any protocol)
     0x04 …                  repeat/hold send (frame A / optional toggle frame B)
     0x05 <protocol> <srcReg> encode a code held in a register on-device (NEC/RC6) and send */
final class IRModuleHandler: ModuleHandler {
  let id: UInt8 = 0x01
  let major: UInt8 = 1
  let minor: UInt8 = 0
  let name: StaticString = "ir"

  var txPin: Int32 = -1
  var rxPin: Int32 = -1
  var dstReg = 0
  var rxBuf = [Int32](repeating: 0, count: 192)    // reused; no per-tick allocation
  var rawBuf = [Int32](repeating: 0, count: 160)   // reused; staged send durations (op 0x03/0x04/0x05)
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

  func handle(_ payload: [UInt8], _ length: Int) {
    if length < 1 { return }
    switch payload[0] {
    case 0x00:
      // Configure the TX pin. The carrier is set per send by the raw op (0x03).
      if length >= 2 && fm_rmt_tx_init(Int32(payload[1] & 0x7F), 0) != 0 { txPin = Int32(payload[1] & 0x7F) }
    case 0x02:
      if length >= 3 && fm_rmt_rx_init(Int32(payload[1] & 0x7F)) != 0 {
        rxPin = Int32(payload[1] & 0x7F)
        dstReg = Int(payload[2] & REG_MASK)
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
      // (38 kHz), 1 = RC6 (36 kHz). Lets a task replay a received/computed code the host can't pre-encode.
      if length >= 3 && txPin >= 0 {
        let proto = payload[1] & 0x7F
        let code = UInt32(bitPattern: scheduler.regs[Int(payload[2] & REG_MASK)])
        _ = fm_rmt_tx_carrier(txPin, 0, 33, (proto == 1 ? 36 : 38) * 1000)
        txRepeatLeft = 0
        txCount = proto == 1 ? encodeRC6(code, bits: 20) : encodeNEC(code)
        txNA = txCount
        txFrame(0)
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
    let captureCount = rxBuf.withUnsafeMutableBufferPointer { fm_rmt_rx_poll($0.baseAddress, 192) }
    #if IR_DEBUG
    if captureCount > 0 {                            // stash every capture for the 0x7E dump
      captureTotal += 1
      lastCaptureCount = min(Int(captureCount), 40)
      for index in 0..<lastCaptureCount { lastCapture[index] = rxBuf[index] }
    }
    #endif
    if captureCount < 66 { return }
    // Find the 9 ms / 4.5 ms header, then read 32 mark/space bit pairs.
    var index = 0
    while index + 1 < Int(captureCount) && !(near(rxBuf[index], 9000) && near(rxBuf[index + 1], 4500)) { index += 1 }
    if index + 66 > Int(captureCount) { return }
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
    scheduler.regs[dstReg] = Int32(bitPattern: code)
    var out: [UInt8] = [START_SYSEX, MODULE_DATA, id, 0x03]
    var remaining = code
    for _ in 0..<5 { out.append(UInt8(remaining & 0x7F)); remaining >>= 7 }
    out.append(END_SYSEX)
    sendFrame(out, out.count)
  }
}
