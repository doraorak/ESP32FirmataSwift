// Periodic sampling (device -> host) and the generic module subsystem (SysEx 0x0D dispatch).

/* ==== Periodic sampling (device -> host) ================================ */

// Scan every reporting-enabled digital port; emit a port update when any pin changed.
func checkDigitalInputs() {
  for port in 0..<NUM_PORTS {
    if !reportPort[port] { continue }
    var mask: UInt8 = 0
    for bit in 0..<8 {
      let pin = port * 8 + bit
      if pin >= TOTAL_PINS { break }
      if !isUsable(pin) || !pinConfigured[pin] { continue }
      let mode = pinModes[pin]
      if mode == PIN_MODE_INPUT || mode == PIN_MODE_PULLUP {
        if digitalRead(UInt8(pin)) != 0 { mask |= (UInt8(1) << bit) }
      } else if mode == PIN_MODE_OUTPUT {
        if pinValues[pin] != 0 { mask |= (UInt8(1) << bit) }
      }
    }
    if mask != previousPort[port] { previousPort[port] = mask; sendDigitalPort(port, mask) }
  }
}

// Emit analog reports for enabled channels — ADC on 0–5, touch sensors on 6–15 —
// then service continuous I2C reads.
func sampleAnalogAndI2C() {
  for channel in 0..<16 where (analogReportMask & (UInt16(1) << channel)) != 0 {
    if channel < NUM_ANALOG {
      let pin = pinOfAnalogChannel(channel)
      if pin >= 0 { sendAnalogReport(channel, Int(analogRead(UInt8(pin)))) }
    } else {
      // An enabled touch channel is the host asking for this sensor — report it
      // unconditionally. `touchRead` auto-inits the pad, so don't gate on pinMode
      // (which could silently drop reports and freeze the host's scope at "sampling").
      let pin = pinOfTouchChannel(channel)
      if pin >= 0 { sendAnalogReport(channel, Int(fm_touch_read(Int32(pin)))) }
    }
  }
  for index in 0..<MAX_CONT_READS where contReads[index].active {
    i2cRead(contReads[index].address, contReads[index].reg, contReads[index].count)
  }
}

/* ==== Module subsystem ====================================================
   Compile-time firmware plugins behind one reserved SysEx (MODULE_DATA 0x0D)
   and one task ext op (MODULE_OP 0x33). A module is native Embedded Swift; the
   C++ shim only exposes peripherals. Discovery: MODULE_QUERY lists (id, ver,
   name). Convention: modules read their own payloads and put results in the
   scheduler registers, which plugs them into ifTrue/tasks for free. */

/* A firmware module is a class conforming to `ModuleHandler`: it owns its state, handles the
   wire payloads addressed to its `id` (via MODULE_DATA 0x0D / MODULE_OP 0x33), and is `tick`ed
   every main-loop iteration. Register a new module by adding an instance to `modules` below —
   discovery (MODULE_QUERY) and dispatch pick it up automatically from `id`/`major`/`minor`/`name`. */
protocol ModuleHandler: AnyObject {
  var id: UInt8 { get }
  var major: UInt8 { get }
  var minor: UInt8 { get }
  var name: StaticString { get }
  func handle(_ payload: [UInt8], _ length: Int)
  func tick()
  /// Drop any peripheral state on SYSTEM_RESET. Needed because `systemResetState()` sets
  /// every pin back to input mode — which detaches an RMT receiver from its pin — so a
  /// module holding a receiver must forget it and re-arm on the next op.
  func reset()
}
extension ModuleHandler { func reset() {} }

/* Every compiled-in module, in one place. */
let modules: [ModuleHandler] = [
  IRModuleHandler(),
  SonarModuleHandler(),
  DHTModuleHandler(),
  DisplayModuleHandler(),
  MicModuleHandler(),
]

func moduleDispatch(_ id: UInt8, _ payload: [UInt8], _ count: Int) {
  for module in modules where module.id == id { module.handle(payload, count); return }
}

func moduleTick() {
  for module in modules { module.tick() }
}

func moduleReset() {
  for module in modules { module.reset() }
}

func handleModuleData(_ data: [UInt8], _ length: Int) {
  if length < 1 { return }
  if data[0] == MODULE_QUERY {
    var index = 0
    frameBuf[index] = START_SYSEX; index += 1
    frameBuf[index] = MODULE_DATA; index += 1
    frameBuf[index] = MODULE_LIST_REPLY; index += 1
    frameBuf[index] = UInt8(modules.count); index += 1
    for module in modules {
      frameBuf[index] = module.id; index += 1
      frameBuf[index] = module.major; index += 1
      frameBuf[index] = module.minor; index += 1
      frameBuf[index] = UInt8(module.name.utf8CodeUnitCount); index += 1
      module.name.withUTF8Buffer { utf8 in
        for byte in utf8 { frameBuf[index] = byte & 0x7F; index += 1 }
      }
    }
    frameBuf[index] = END_SYSEX; index += 1
    sendFrame(frameBuf, index)
    return
  }
  moduleDispatch(data[0], Array(data[1..<length]), length - 1)
}
