// Sonar module (id 0x02): HC-SR04 ultrasonic distance over trigger/echo pins.

/* ==== Sonar module — a ModuleHandler ======================================
   Distance lands in a scheduler register (cm), so tasks branch on it directly
   (`ifTrue(.reg(n), .lessThan, .number(20)) { … }`). Ops:
     0x00 <trig> <echo>                  configure the pin pair
     0x01 <dstReg>                       ping once now → R[dstReg] = cm (-1 = no echo)
     0x02 <dstReg> <perLo> <perHi>       auto-ping every period ms → R[dstReg]; period 0 stops
   A ping blocks up to ~25 ms (4 m round trip) — fine at handle/tick cadence. */
final class SonarModuleHandler: ModuleHandler {
  let id: UInt8 = 0x02
  let major: UInt8 = 1
  let minor: UInt8 = 1              // 1.1: op 0x03 one-shot ping → host reply
  let name: StaticString = "sonar"

  var trigPin: Int32 = -1
  var echoPin: Int32 = -1
  var autoReg = 0
  var autoPeriodMs: UInt32 = 0        // 0 = auto-ping off
  var nextPingMs: UInt32 = 0

  /// One blocking ping → centimetres (µs / 58), or -1 when nothing echoed in range.
  func pingCm() -> Int32 {
    if trigPin < 0 || echoPin < 0 { return -1 }
    let us = fm_sonar_ping_us(trigPin, echoPin, 25000)   // ~4.3 m ceiling
    return us > 0 ? us / 58 : -1
  }

  func handle(_ payload: [UInt8], _ length: Int) {
    if length < 1 { return }
    switch payload[0] {
    case 0x00:                        // configure: trig, echo
      if length >= 3 {
        trigPin = Int32(payload[1] & 0x7F)
        echoPin = Int32(payload[2] & 0x7F)
        fm_pin_mode(trigPin, 1)       // OUTPUT
        fm_pin_mode(echoPin, 0)       // INPUT
      }
    case 0x01:                        // ping once → R[dst]
      if length >= 2 { scheduler.regs[Int(payload[1] & REG_MASK)] = pingCm() }
    case 0x02:                        // auto-ping every period ms → R[dst]; 0 stops
      if length >= 4 {
        autoReg = Int(payload[1] & REG_MASK)
        autoPeriodMs = UInt32(payload[2] & 0x7F) | (UInt32(payload[3] & 0x7F) << 7)
        nextPingMs = fm_millis()
      }
    case 0x03:                        // one-shot: ping now, reply cm to the host (no register)
      var out: [UInt8] = [START_SYSEX, MODULE_DATA, id, 0x03]
      var v = UInt32(bitPattern: pingCm())        // cm (-1 = no echo) as 5×7-bit limbs
      for _ in 0..<5 { out.append(UInt8(v & 0x7F)); v >>= 7 }
      out.append(END_SYSEX)
      sendFrame(out, out.count)
    default: break
    }
  }

  func tick() {
    if autoPeriodMs == 0 || trigPin < 0 { return }
    let now = fm_millis()
    if Int32(bitPattern: now &- nextPingMs) < 0 { return }
    scheduler.regs[autoReg] = pingCm()
    nextPingMs = now &+ autoPeriodMs
  }
}
