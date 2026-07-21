// Mic module (id 0x05): sound level off an analog microphone — RMS windows → decibels.

/* ==== Mic module — a ModuleHandler ========================================
   The host's ~10 Hz analog stream can't measure loudness (audio is 100 Hz–8 kHz;
   sparse samples alias). This module burst-samples the ADC on-device each window,
   computes the DC-removed RMS, converts to decibels, and drops both into scheduler
   registers — so tasks branch on loudness (`ifTrue(.freg(n), .greaterThan, 60)`)
   and the host just reads registers. dB is relative full-scale by default
   (0 dB ≈ full-scale sine); a stored offset shifts it to ~SPL after a one-point
   calibration against any reference meter.
   Two mic kinds share this module — an ANALOG mic on an ADC pin (op 0x00), and a
   DIGITAL I2S MEMS mic like the INMP441 (op 0x03). Both reduce to the same on-device
   RMS→dB path; only the sampling source and the full-scale reference differ.
   Ops:
     0x00 <pin> <dbFReg> <rmsReg> <winLo> <winHi>            analog configure + windows (ms, ≥50)
     0x01                                                    read now → reply [0x01 ok db:5 rms:5]
     0x02 <offBits:5>                                        set calibration offset (dB, IEEE-754)
     0x03 <bclk> <ws> <sd> <dbFReg> <rmsReg> <winLo> <winHi> [<rate:3>]  I2S configure (INMP441);
                                                             optional 3×7-bit sample rate (default 16 kHz)
     0x05 <hzFReg | 0x7F>                                    I2S dominant-frequency (FFT) → F[hzFReg]; 0x7F = off
   A window's burst blocks ~16 ms — same class as a sonar ping, fine at tick cadence. */
final class MicModuleHandler: ModuleHandler {
  let id: UInt8 = 0x05
  let major: UInt8 = 1
  let minor: UInt8 = 2              // 1.2: I2S sample rate + op 0x05 dominant frequency
  let name: StaticString = "mic"

  var pin: Int32 = -1                 // -1 = unconfigured (analog)
  var i2sMode = false                 // true = digital I2S mic (INMP441), pin ignored
  var sampleRate: Int32 = 16000       // I2S audio rate (Hz); host-settable, drives Hz mapping
  var hzFReg = -1                     // -1 = dominant-frequency detection off (I2S only)
  var dbFReg = 0
  var rmsReg = 0
  var windowMs: UInt32 = 250
  var nextWindowMs: UInt32 = 0
  var offsetDb: Float = 0             // calibration: survives reset() on purpose

  var configured: Bool { i2sMode || pin >= 0 }

  /// One block of samples → DC-removed RMS. I2S reads a DMA block (24-bit MEMS data);
  /// analog burst-samples the ADC for ~16 ms. RMS is around the measured mean, so any
  /// DC bias cancels out.
  func measureRms() -> Float {
    if i2sMode { return fm_i2s_mic_rms() }
    if pin < 0 { return -1 }
    var sum: Int64 = 0
    var sumSq: Int64 = 0
    var n: Int64 = 0
    let start = fm_millis()
    while fm_millis() &- start < 16 {
      let v = Int64(analogRead(UInt8(pin & 0xFF)))
      sum &+= v
      sumSq &+= v &* v
      n &+= 1
    }
    if n < 8 { return -1 }
    let mean = Double(sum) / Double(n)
    var variance = Double(sumSq) / Double(n) - mean * mean
    if variance < 0 { variance = 0 }
    return Float(variance.squareRoot())
  }

  /// rms → dB relative to full scale, floored so silence gives a real number not -inf.
  /// Reference differs by source: 12-bit ADC full-scale sine ≈ 2048/√2; I2S 24-bit ≈ 2^23.
  func decibels(_ rms: Float) -> Float {
    let r = rms < 0.5 ? 0.5 : rms
    let ref: Float = i2sMode ? 8_388_608.0 : 1448.0
    return 20 * fm_log10f(r / ref) + offsetDb
  }

  func handle(_ payload: [UInt8], _ length: Int) {
    if length < 1 { return }
    switch payload[0] {
    case 0x00:                        // analog configure: pin, F[db], R[rms], window ms
      if length >= 6 {
        i2sMode = false
        pin = Int32(payload[1] & 0x7F)
        dbFReg = Int(payload[2] & FREG_MASK)
        rmsReg = Int(payload[3] & REG_MASK)
        windowMs = UInt32(payload[4] & 0x7F) | (UInt32(payload[5] & 0x7F) << 7)
        if windowMs < 50 { windowMs = 50 }
        fm_analog_setup()             // 12-bit, full attenuation (idempotent)
        nextWindowMs = fm_millis()
      }
    case 0x03:                        // I2S configure: bclk, ws, sd, F[db], R[rms], winLo, winHi, [rate:3]
      if length >= 8 {
        dbFReg = Int(payload[4] & FREG_MASK)
        rmsReg = Int(payload[5] & REG_MASK)
        windowMs = UInt32(payload[6] & 0x7F) | (UInt32(payload[7] & 0x7F) << 7)
        if windowMs < 50 { windowMs = 50 }
        var rate: Int32 = 16000                     // default; optional 3×7-bit rate follows
        if length >= 11 {
          rate = Int32(UInt32(payload[8] & 0x7F) | (UInt32(payload[9] & 0x7F) << 7)
                       | (UInt32(payload[10] & 0x7F) << 14))
        }
        if rate < 8000 { rate = 8000 }
        if rate > 48000 { rate = 48000 }
        if fm_i2s_mic_begin(Int32(payload[1] & 0x7F), Int32(payload[2] & 0x7F),
                            Int32(payload[3] & 0x7F), rate) != 0 {
          i2sMode = true; pin = -1
          sampleRate = rate
          nextWindowMs = fm_millis()
        }
      }
    case 0x01:                        // one-shot: measure now, reply db+rms to the host
      let rms = measureRms()
      let ok: UInt8 = rms < 0 ? 0 : 1
      let db = rms < 0 ? Float(0) : decibels(rms)
      var out: [UInt8] = [START_SYSEX, MODULE_DATA, id, 0x01, ok]
      var db_ = db.bitPattern                     // dB as 5×7-bit limbs of the IEEE-754 bits
      for _ in 0..<5 { out.append(UInt8(db_ & 0x7F)); db_ >>= 7 }
      var r = UInt32(rms < 0 ? 0 : rms)           // raw RMS counts as 5×7-bit limbs
      for _ in 0..<5 { out.append(UInt8(r & 0x7F)); r >>= 7 }
      out.append(END_SYSEX)
      sendFrame(out, out.count)
    case 0x02:                        // calibration offset (dB), IEEE-754 bits in 5 limbs
      if length >= 6 {
        var bits: UInt32 = 0
        for i in (1...5).reversed() { bits = (bits << 7) | UInt32(payload[i] & 0x7F) }
        offsetDb = Float(bitPattern: bits)
      }
    case 0x04:                        // I2S diagnostic: reply the raw peak sample [0x04 peak:5]
      let peak = i2sMode ? fm_i2s_mic_peak_raw() : Int32(-1)
      var out: [UInt8] = [START_SYSEX, MODULE_DATA, id, 0x04]
      var p = UInt32(bitPattern: peak)
      for _ in 0..<5 { out.append(UInt8(p & 0x7F)); p >>= 7 }
      out.append(END_SYSEX)
      sendFrame(out, out.count)
    case 0x05:                        // enable/disable dominant-frequency (I2S) → F[hzFReg]; 0x7F = off
      if length >= 2 {
        hzFReg = (payload[1] == 0x7F) ? -1 : Int(payload[1] & FREG_MASK)
      }
    default: break
    }
  }

  func tick() {
    if !configured { return }
    let now = fm_millis()
    if Int32(bitPattern: now &- nextWindowMs) < 0 { return }
    let rms = measureRms()
    if rms >= 0 {
      scheduler.fregs[dbFReg] = decibels(rms)
      scheduler.regs[rmsReg] = Int32(rms)
    }
    if i2sMode && hzFReg >= 0 {
      let hz = fm_i2s_mic_dominant_hz(sampleRate)
      if hz >= 0 { scheduler.fregs[hzFReg] = hz }   // 0 = no dominant tone; <0 = read error (skip)
    }
    nextWindowMs = now &+ windowMs
  }

  func reset() {
    pin = -1; i2sMode = false; hzFReg = -1   // offsetDb kept: calibration outlives sessions
  }
}
