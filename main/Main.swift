/*
 * ESP32 Firmata firmware in Embedded Swift — entry point.
 *
 * The firmware is split across several files, all compiled as one module
 * (-wmo), so declaration order *between* files does not matter:
 *
 *   FirmataProtocol.swift  identity, protocol constants, pin model
 *   RuntimeState.swift     value types, pin/reporting state, PWM
 *   Messaging.swift        outgoing transport + messages, pin/I2C handlers
 *   LiveProtocol.swift     live SysEx dispatch
 *   Encoder7Bit.swift      7-bit SysEx packing
 *   Scheduler.swift        Scheduler + on-device task extension (ext ops 0x10-0x30)
 *   Modules.swift          periodic sampling + module subsystem
 *   IRModule.swift         IR module (NEC/RC6/raw over RMT)
 *   Session.swift          reset + per-iteration periodic work
 *   Configuration.swift    Wi-Fi credentials, board/BLE names
 *   Transport.swift        Wi-Fi/Bonjour + BLE orchestration
 *   Main.swift             this file - sw_main entry; Swift owns the run loop
 *
 * Hardware and radio access goes through the `fm_*` C functions in
 * firmata_shim.cpp; C calls back in through the `sw_*` entry points. Swift owns
 * the run loop.
 */

@_cdecl("sw_main")
public func sw_main() {
  // Wire the handler/scheduler cross-references (singletons that live forever).
  liveHandler.sched   = scheduler
  replayHandler.sched = scheduler
  scheduler.replay    = replayHandler

  fm_serial_begin(115200)
  fm_delay_ms(200)
  fm_log(cs("=== ESP32 Firmata (Embedded Swift) : FirmataESP32 ==="))
  fm_analog_setup()
  systemResetState()
  wifiStart()
  fm_ble_begin(cs(BLE_NAME))
  fm_log(cs("BLE advertising (Nordic UART Service)"))
  while true {
    tcpPoll()
    blePoll()
    serialPoll()
    loopTick()
    fm_delay_ms(1)
  }
}
