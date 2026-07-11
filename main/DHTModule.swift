// DHT module (id 0x03): DHT11/DHT22 temperature + humidity on one data pin.

/* ==== DHT module — a ModuleHandler ========================================
   Results land in float registers (°C / %RH) plus an ok-flag int register, so a
   task is a thermostat for free (`ifTrue(.freg(n), .greaterThan, .float(28)) { … }`).
   Ops:
     0x00 <pin> <type> <tempF> <humF> <statusReg>   configure + start auto-reads
     0x01                                           force a read on the next tick
   type: 0 = DHT11, 1 = DHT22. The sensor allows one read per ~2 s; the module
   auto-reads on that cadence. A failed read sets R[status] = 0 and keeps the
   previous values; success sets R[status] = 1. */
final class DHTModuleHandler: ModuleHandler {
  let id: UInt8 = 0x03
  let major: UInt8 = 1
  let minor: UInt8 = 0
  let name: StaticString = "dht"

  var pin: Int32 = -1
  var sensorType: Int32 = 0
  var tempFReg = 0
  var humFReg = 0
  var statusReg = 0
  var nextReadMs: UInt32 = 0
  let READ_PERIOD_MS: UInt32 = 2000   // datasheet minimum interval

  func handle(_ payload: [UInt8], _ length: Int) {
    if length < 1 { return }
    switch payload[0] {
    case 0x00:                        // configure: pin, type, tempFReg, humFReg, statusReg
      if length >= 6 {
        pin        = Int32(payload[1] & 0x7F)
        sensorType = Int32(payload[2] & 0x7F)
        tempFReg   = Int(payload[3] & FREG_MASK)
        humFReg    = Int(payload[4] & FREG_MASK)
        statusReg  = Int(payload[5] & REG_MASK)
        nextReadMs = fm_millis()      // first read on the next tick
      }
    case 0x01:                        // read now
      nextReadMs = fm_millis()
    default: break
    }
  }

  func tick() {
    if pin < 0 { return }
    let now = fm_millis()
    if Int32(bitPattern: now &- nextReadMs) < 0 { return }
    nextReadMs = now &+ READ_PERIOD_MS
    var t: Float = 0
    var h: Float = 0
    if fm_dht_read(pin, sensorType, &t, &h) == 0 {
      scheduler.fregs[tempFReg] = t
      scheduler.fregs[humFReg]  = h
      scheduler.regs[statusReg] = 1
    } else {
      scheduler.regs[statusReg] = 0   // keep last good values in the float regs
    }
  }
}
