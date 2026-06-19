//===----------------------------------------------------------------------===//
// Main.swift — Embedded Swift port of ESP32Firmata.ino (Firmata 2.x firmware).
//
// A faithful, section-by-section conversion of the original Arduino sketch's
// protocol logic to Embedded Swift: the Firmata parser & message builders, pin
// I/O handlers, I2C logic, the Firmata Scheduler (Encoder7Bit packing) and the
// non-standard on-device register/if-else logic extension (see NONSTANDARD.md).
//
// Everything that can't be expressed in Embedded Swift — the Arduino hardware
// APIs and the Wi-Fi/TCP+Bonjour transport — lives in firmata_shim.cpp and is
// reached through the `fm_*` C functions. The transport calls back into the
// `sw_*` entry points at the bottom of this file.
//
// Transport scope: Wi-Fi + Bonjour only (BLE omitted by request).
//===----------------------------------------------------------------------===//

// ===========================================================================
//  Firmware identity (firmware-report message)
// ===========================================================================
let FIRMWARE_NAME: StaticString = "FirmataESP32"
let FIRMWARE_MAJOR: UInt8 = 2
let FIRMWARE_MINOR: UInt8 = 8
let PROTOCOL_MAJOR: UInt8 = 2
let PROTOCOL_MINOR: UInt8 = 8

// ===========================================================================
//  Firmata protocol constants
// ===========================================================================
let ANALOG_MESSAGE: UInt8        = 0xE0
let DIGITAL_MESSAGE: UInt8       = 0x90
let REPORT_ANALOG: UInt8         = 0xC0
let REPORT_DIGITAL: UInt8        = 0xD0
let SET_PIN_MODE: UInt8          = 0xF4
let SET_DIGITAL_PIN_VALUE: UInt8 = 0xF5
let REPORT_VERSION: UInt8        = 0xF9
let SYSTEM_RESET: UInt8          = 0xFF
let START_SYSEX: UInt8           = 0xF0
let END_SYSEX: UInt8             = 0xF7

let ANALOG_MAPPING_QUERY: UInt8    = 0x69
let ANALOG_MAPPING_RESPONSE: UInt8 = 0x6A
let CAPABILITY_QUERY: UInt8        = 0x6B
let CAPABILITY_RESPONSE: UInt8     = 0x6C
let PIN_STATE_QUERY: UInt8         = 0x6D
let PIN_STATE_RESPONSE: UInt8      = 0x6E
let EXTENDED_ANALOG: UInt8         = 0x6F
let STRING_DATA: UInt8             = 0x71
let I2C_REQUEST: UInt8             = 0x76
let I2C_REPLY: UInt8               = 0x77
let I2C_CONFIG: UInt8              = 0x78
let REPORT_FIRMWARE: UInt8         = 0x79
let SAMPLING_INTERVAL: UInt8       = 0x7A
let SCHEDULER_DATA: UInt8          = 0x7B

// Scheduler sub-commands
let SCHED_CREATE: UInt8          = 0x00
let SCHED_DELETE: UInt8          = 0x01
let SCHED_ADD: UInt8             = 0x02
let SCHED_DELAY: UInt8           = 0x03
let SCHED_SCHEDULE: UInt8        = 0x04
let SCHED_QUERY_ALL: UInt8       = 0x05
let SCHED_QUERY: UInt8           = 0x06
let SCHED_RESET: UInt8           = 0x07
let SCHED_ERROR_REPLY: UInt8     = 0x08
let SCHED_QUERY_ALL_REPLY: UInt8 = 0x09
let SCHED_QUERY_REPLY: UInt8     = 0x0A

// Logic extension (NONSTANDARD.md) under EXTENDED_SCHEDULER_COMMAND (0x7F)
let SCHED_EXT_COMMAND: UInt8      = 0x7F
let SCHED_EXT_SET: UInt8          = 0x10
let SCHED_EXT_READ_DIGITAL: UInt8 = 0x11
let SCHED_EXT_READ_ANALOG: UInt8  = 0x12
let SCHED_EXT_IF: UInt8           = 0x13
let SCHED_EXT_SKIP: UInt8         = 0x14

// Pin modes
let PIN_MODE_INPUT: UInt8  = 0x00
let PIN_MODE_OUTPUT: UInt8 = 0x01
let PIN_MODE_ANALOG: UInt8 = 0x02
let PIN_MODE_PWM: UInt8    = 0x03
let PIN_MODE_I2C: UInt8    = 0x06
let PIN_MODE_PULLUP: UInt8 = 0x0B

// ===========================================================================
//  ESP32 pin model
// ===========================================================================
let TOTAL_PINS = 40
let NUM_PORTS  = (TOTAL_PINS + 7) / 8          // 5
let ANALOG_PINS: [Int] = [32, 33, 34, 35, 36, 39]
let NUM_ANALOG = 6
let I2C_SDA_PIN = 21
let I2C_SCL_PIN = 22

func isFullDigital(_ pin: Int) -> Bool {
  switch pin {
  case 0, 2, 4, 5, 12, 13, 14, 15, 16, 17, 18, 19, 21, 22, 23, 25, 26, 27, 32, 33: return true
  default: return false
  }
}
func isInputOnly(_ pin: Int) -> Bool { pin == 34 || pin == 35 || pin == 36 || pin == 39 }
func isUsable(_ pin: Int) -> Bool { isFullDigital(pin) || isInputOnly(pin) }
func analogChannelOfPin(_ pin: Int) -> Int {
  for i in 0..<NUM_ANALOG where ANALOG_PINS[i] == pin { return i }
  return -1
}
func pinOfAnalogChannel(_ ch: Int) -> Int { (ch >= 0 && ch < NUM_ANALOG) ? ANALOG_PINS[ch] : -1 }

// ===========================================================================
//  Parser + scheduler types
// ===========================================================================
let SYSEX_MAX = 256

struct ParserState {
  var parsingSysex = false
  var waitForData = 0
  var executeMultiByteCommand: UInt8 = 0
  var multiByteChannel: UInt8 = 0
  var storedInputData = [UInt8](repeating: 0, count: 2)  // [1]=first byte, [0]=second
  var sysexBuffer = [UInt8](repeating: 0, count: SYSEX_MAX)
  var sysexBytesRead = 0
}

let MAX_TASKS = 8
let MAX_TASK_BYTES = 512

final class SchedTask {
  var used = false
  var id: UInt8 = 0
  var time_ms: UInt32 = 0       // absolute millis() when due; 0 = not scheduled
  var len: UInt16 = 0
  var pos: UInt16 = 0
  var data = [UInt8](repeating: 0, count: MAX_TASK_BYTES)
}

// ===========================================================================
//  Runtime pin / reporting state
// ===========================================================================
var pinModes      = [UInt8](repeating: PIN_MODE_INPUT, count: TOTAL_PINS)
var pinValues     = [Int](repeating: 0, count: TOTAL_PINS)
var pinConfigured = [Bool](repeating: false, count: TOTAL_PINS)
var analogReportMask: UInt16 = 0
var reportPort    = [Bool](repeating: false, count: NUM_PORTS)
var previousPort  = [UInt8](repeating: 0, count: NUM_PORTS)

var samplingInterval: UInt16 = 19
let MIN_SAMPLING: UInt16 = 10
var lastSampleMs: UInt32 = 0

// I2C
var i2cReadDelayUs: UInt16 = 0
struct ContinuousRead { var address: UInt16 = 0; var reg: Int = -1; var count: UInt16 = 0; var active = false }
let MAX_CONT_READS = 8
var contReads = [ContinuousRead](repeating: ContinuousRead(), count: MAX_CONT_READS)

// Parser + scheduler instances
var liveParser = ParserState()
var taskParser = ParserState()
var schedTasks: [SchedTask] = {
  var a: [SchedTask] = []
  for _ in 0..<MAX_TASKS { a.append(SchedTask()) }
  return a
}()
var runningTask: SchedTask? = nil
let NUM_SCHED_REGS = 16
var schedReg = [Int32](repeating: 0, count: NUM_SCHED_REGS)

// Scratch buffer used to build outgoing frames.
var frameBuf = [UInt8](repeating: 0, count: 1024)

// Dual-transport master arbitration (latest-wins). Wi-Fi-only build -> TCP/none.
let TR_NONE: UInt8 = 0
let TR_TCP: UInt8  = 1
let TR_BLE: UInt8  = 2
var activeTransport: UInt8 = TR_NONE

// ===========================================================================
//  PWM -> Arduino analogWrite (LEDC). Firmata duty is 8-bit (0..255).
// ===========================================================================
@inline(__always) func pwm(_ pin: Int, _ value: Int) {
  let v = value < 0 ? 0 : (value > 255 ? 255 : value)
  analogWrite(UInt8(pin), Int32(v))
}

// ===========================================================================
//  Outgoing frame transport (routes to the current master)
// ===========================================================================
func sendFrame(_ buf: [UInt8], _ len: Int) {
  if activeTransport == TR_TCP {
    buf.withUnsafeBufferPointer { fm_tcp_write($0.baseAddress, Int32(len)) }
  } else if activeTransport == TR_BLE {
    bleSend(buf, len)
  }
}

// ===========================================================================
//  Outgoing Firmata messages
// ===========================================================================
func sendProtocolVersion() { sendFrame([REPORT_VERSION, PROTOCOL_MAJOR, PROTOCOL_MINOR], 3) }

func sendFirmwareReport() {
  var n = 0
  frameBuf[n] = START_SYSEX;     n += 1
  frameBuf[n] = REPORT_FIRMWARE; n += 1
  frameBuf[n] = FIRMWARE_MAJOR;  n += 1
  frameBuf[n] = FIRMWARE_MINOR;  n += 1
  FIRMWARE_NAME.withUTF8Buffer { name in
    for c in name { frameBuf[n] = c & 0x7F; n += 1; frameBuf[n] = (c >> 7) & 0x7F; n += 1 }
  }
  frameBuf[n] = END_SYSEX; n += 1
  sendFrame(frameBuf, n)
}

func sendCapabilityResponse() {
  var n = 0
  frameBuf[n] = START_SYSEX;          n += 1
  frameBuf[n] = CAPABILITY_RESPONSE;  n += 1
  for pin in 0..<TOTAL_PINS {
    if isFullDigital(pin) {
      frameBuf[n] = PIN_MODE_INPUT;  n += 1; frameBuf[n] = 1; n += 1
      frameBuf[n] = PIN_MODE_PULLUP; n += 1; frameBuf[n] = 1; n += 1
      frameBuf[n] = PIN_MODE_OUTPUT; n += 1; frameBuf[n] = 1; n += 1
      frameBuf[n] = PIN_MODE_PWM;    n += 1; frameBuf[n] = 8; n += 1
      if pin == I2C_SDA_PIN || pin == I2C_SCL_PIN { frameBuf[n] = PIN_MODE_I2C; n += 1; frameBuf[n] = 1; n += 1 }
      if analogChannelOfPin(pin) >= 0 { frameBuf[n] = PIN_MODE_ANALOG; n += 1; frameBuf[n] = 12; n += 1 }
    } else if isInputOnly(pin) {
      frameBuf[n] = PIN_MODE_INPUT; n += 1; frameBuf[n] = 1; n += 1
      if analogChannelOfPin(pin) >= 0 { frameBuf[n] = PIN_MODE_ANALOG; n += 1; frameBuf[n] = 12; n += 1 }
    }
    frameBuf[n] = 0x7F; n += 1   // end of this pin's capabilities
  }
  frameBuf[n] = END_SYSEX; n += 1
  sendFrame(frameBuf, n)
}

func sendAnalogMappingResponse() {
  var n = 0
  frameBuf[n] = START_SYSEX;             n += 1
  frameBuf[n] = ANALOG_MAPPING_RESPONSE; n += 1
  for pin in 0..<TOTAL_PINS {
    let ch = analogChannelOfPin(pin)
    frameBuf[n] = (ch >= 0) ? UInt8(ch) : 0x7F; n += 1
  }
  frameBuf[n] = END_SYSEX; n += 1
  sendFrame(frameBuf, n)
}

func sendPinStateResponse(_ pin: Int) {
  if pin >= TOTAL_PINS { return }
  var n = 0
  frameBuf[n] = START_SYSEX;        n += 1
  frameBuf[n] = PIN_STATE_RESPONSE; n += 1
  frameBuf[n] = UInt8(pin);         n += 1
  frameBuf[n] = pinModes[pin];      n += 1
  var v = UInt32(pinValues[pin] < 0 ? 0 : pinValues[pin])
  frameBuf[n] = UInt8(v & 0x7F); n += 1; v >>= 7
  while v != 0 { frameBuf[n] = UInt8(v & 0x7F); n += 1; v >>= 7 }
  frameBuf[n] = END_SYSEX; n += 1
  sendFrame(frameBuf, n)
}

func sendAnalogReport(_ channel: Int, _ value: Int) {
  sendFrame([ANALOG_MESSAGE | (UInt8(channel) & 0x0F), UInt8(value & 0x7F), UInt8((value >> 7) & 0x7F)], 3)
}

func sendDigitalPort(_ port: Int, _ mask: UInt8) {
  sendFrame([DIGITAL_MESSAGE | (UInt8(port) & 0x0F), mask & 0x7F, (mask >> 7) & 0x01], 3)
}

func sendI2CReply(_ address: UInt16, _ reg: Int, _ data: [UInt8], _ count: Int) {
  var n = 0
  frameBuf[n] = START_SYSEX; n += 1
  frameBuf[n] = I2C_REPLY;   n += 1
  frameBuf[n] = UInt8(address & 0x7F);        n += 1
  frameBuf[n] = UInt8((address >> 7) & 0x7F); n += 1
  let r = UInt16(reg < 0 ? 0 : reg)
  frameBuf[n] = UInt8(r & 0x7F);        n += 1
  frameBuf[n] = UInt8((r >> 7) & 0x7F); n += 1
  for i in 0..<count {
    frameBuf[n] = data[i] & 0x7F;        n += 1
    frameBuf[n] = (data[i] >> 7) & 0x7F; n += 1
  }
  frameBuf[n] = END_SYSEX; n += 1
  sendFrame(frameBuf, n)
}

// ===========================================================================
//  Pin I/O handlers
// ===========================================================================
func handleSetPinMode(_ pin: Int, _ mode: UInt8) {
  if pin >= TOTAL_PINS { return }
  switch mode {
  case PIN_MODE_INPUT:
    if isUsable(pin) { fm_pin_mode(Int32(pin), 0); pinModes[pin] = mode; pinConfigured[pin] = true }
  case PIN_MODE_PULLUP:
    if isFullDigital(pin) { fm_pin_mode(Int32(pin), 2); pinModes[pin] = mode; pinValues[pin] = 1; pinConfigured[pin] = true }
  case PIN_MODE_OUTPUT:
    if isFullDigital(pin) { fm_pin_mode(Int32(pin), 1); pinModes[pin] = mode; pinConfigured[pin] = true }
  case PIN_MODE_ANALOG:
    if analogChannelOfPin(pin) >= 0 { pinModes[pin] = mode }
  case PIN_MODE_PWM:
    if isFullDigital(pin) { pinModes[pin] = mode; pwm(pin, 0); pinValues[pin] = 0 }
  case PIN_MODE_I2C:
    pinModes[pin] = mode
  default:
    break
  }
}

func handleSetDigitalPinValue(_ pin: Int, _ value: UInt8) {
  if pin >= TOTAL_PINS { return }
  if pinModes[pin] == PIN_MODE_OUTPUT {
    digitalWrite(UInt8(pin), value != 0 ? 1 : 0)
    pinValues[pin] = value != 0 ? 1 : 0
  }
}

func handleDigitalMessage(_ port: Int, _ lsb: UInt8, _ msb: UInt8) {
  let portValue = Int(lsb & 0x7F) | (Int(msb & 0x01) << 7)
  for i in 0..<8 {
    let pin = port * 8 + i
    if pin >= TOTAL_PINS { break }
    if pinModes[pin] == PIN_MODE_OUTPUT {
      let bit = (portValue >> i) & 0x01
      digitalWrite(UInt8(pin), UInt8(bit))
      pinValues[pin] = bit
    }
  }
}

func handleAnalogMessage(_ pin: Int, _ lsb: UInt8, _ msb: UInt8) {
  if pin >= TOTAL_PINS { return }
  let value = Int(lsb & 0x7F) | (Int(msb & 0x7F) << 7)
  if pinModes[pin] == PIN_MODE_PWM { pwm(pin, value); pinValues[pin] = value }
}

func handleReportAnalog(_ channel: Int, _ enable: UInt8) {
  if channel > 15 { return }
  if enable != 0 { analogReportMask |= (UInt16(1) << channel) }
  else           { analogReportMask &= ~(UInt16(1) << channel) }
}

func handleReportDigital(_ port: Int, _ enable: UInt8) {
  if port >= NUM_PORTS { return }
  reportPort[port] = (enable != 0)
  if reportPort[port] {
    var mask: UInt8 = 0
    for i in 0..<8 {
      let pin = port * 8 + i
      if pin >= TOTAL_PINS { break }
      if !isUsable(pin) || !pinConfigured[pin] { continue }
      let m = pinModes[pin]
      if m == PIN_MODE_INPUT || m == PIN_MODE_PULLUP {
        if digitalRead(UInt8(pin)) != 0 { mask |= (UInt8(1) << i) }
      } else if m == PIN_MODE_OUTPUT {
        if pinValues[pin] != 0 { mask |= (UInt8(1) << i) }
      }
    }
    previousPort[port] = mask
    sendDigitalPort(port, mask)
  }
}

func handleExtendedAnalog(_ data: [UInt8], _ len: Int) {
  if len < 1 { return }
  let pin = Int(data[0])
  if pin >= TOTAL_PINS { return }
  var value = 0
  for i in 1..<len { value |= Int(data[i] & 0x7F) << (7 * (i - 1)) }
  if pinModes[pin] == PIN_MODE_PWM { pwm(pin, value); pinValues[pin] = value }
}

// ===========================================================================
//  I2C
// ===========================================================================
func handleI2CConfig(_ data: [UInt8], _ len: Int) {
  fm_i2c_begin(Int32(I2C_SDA_PIN), Int32(I2C_SCL_PIN))
  if len >= 2 { i2cReadDelayUs = UInt16(data[0] & 0x7F) | (UInt16(data[1] & 0x7F) << 7) }
}

func i2cDoRead(_ address: UInt16, _ reg: Int, _ count0: UInt16) {
  if reg >= 0 {
    fm_i2c_begin_transmission(Int32(address))
    fm_i2c_write(Int32(reg))
    _ = fm_i2c_end_transmission(1)
  }
  if i2cReadDelayUs != 0 { fm_delay_us(UInt32(i2cReadDelayUs)) }
  var count = Int(count0); if count > 64 { count = 64 }
  let got = Int(fm_i2c_request_from(Int32(address), Int32(count)))
  var buf = [UInt8](repeating: 0, count: 64)
  var i = 0
  while fm_i2c_available() != 0 && i < got && i < count { buf[i] = UInt8(fm_i2c_read() & 0xFF); i += 1 }
  sendI2CReply(address, reg, buf, i)
}

func addContinuousRead(_ address: UInt16, _ reg: Int, _ count: UInt16) {
  for i in 0..<MAX_CONT_READS where contReads[i].active && contReads[i].address == address {
    contReads[i].reg = reg; contReads[i].count = count; return
  }
  for i in 0..<MAX_CONT_READS where !contReads[i].active {
    contReads[i] = ContinuousRead(address: address, reg: reg, count: count, active: true); return
  }
}

func stopContinuousRead(_ address: UInt16) {
  for i in 0..<MAX_CONT_READS where contReads[i].active && contReads[i].address == address { contReads[i].active = false }
}

func handleI2CRequest(_ data: [UInt8], _ len: Int) {
  if len < 2 { return }
  var address = UInt16(data[0] & 0x7F)
  let control = data[1]
  let mode = (control >> 3) & 0x03
  let tenbit = (control & 0x20) != 0
  if tenbit { address |= UInt16(control & 0x07) << 7 }

  let poff = 2
  let plen = len - 2

  switch mode {
  case 0:  // WRITE
    fm_i2c_begin_transmission(Int32(address))
    var i = 0
    while i + 1 < plen {
      let b = (data[poff + i] & 0x7F) | ((data[poff + i + 1] & 0x7F) << 7)
      fm_i2c_write(Int32(b)); i += 2
    }
    let restart = (control & 0x40) != 0
    _ = fm_i2c_end_transmission(restart ? 0 : 1)   // restart -> no STOP
  case 1:  // READ_ONCE
    var reg = -1; var count: UInt16 = 0
    if plen >= 4 {
      reg   = Int(data[poff] & 0x7F) | (Int(data[poff + 1] & 0x7F) << 7)
      count = UInt16(data[poff + 2] & 0x7F) | (UInt16(data[poff + 3] & 0x7F) << 7)
    } else if plen >= 2 {
      count = UInt16(data[poff] & 0x7F) | (UInt16(data[poff + 1] & 0x7F) << 7)
    }
    i2cDoRead(address, reg, count)
  case 2:  // READ_CONTINUOUS
    var reg = -1; var count: UInt16 = 0
    if plen >= 4 {
      reg   = Int(data[poff] & 0x7F) | (Int(data[poff + 1] & 0x7F) << 7)
      count = UInt16(data[poff + 2] & 0x7F) | (UInt16(data[poff + 3] & 0x7F) << 7)
    } else if plen >= 2 {
      count = UInt16(data[poff] & 0x7F) | (UInt16(data[poff + 1] & 0x7F) << 7)
    }
    addContinuousRead(address, reg, count)
  case 3:  // STOP_READING
    stopContinuousRead(address)
  default:
    break
  }
}

// ===========================================================================
//  SysEx dispatch
// ===========================================================================
func handleString(_ data: [UInt8], _ len: Int) {
  var s = [UInt8](repeating: 0, count: len / 2 + 1)
  var j = 0, i = 0
  while i + 1 < len {
    let cp = Int(data[i] & 0x7F) | (Int(data[i + 1] & 0x7F) << 7)
    if cp < 128 { s[j] = UInt8(cp); j += 1 }
    i += 2
  }
  s[j] = 0
  s.withUnsafeBufferPointer { fm_log($0.baseAddress) }
}

func processSysex(_ buf: [UInt8], _ len: Int) {
  if len < 1 { return }
  let cmd = buf[0]
  let data = Array(buf[1..<len])   // mirrors `data = buf + 1`
  let dlen = len - 1

  switch cmd {
  case REPORT_FIRMWARE:      sendFirmwareReport()
  case CAPABILITY_QUERY:     sendCapabilityResponse()
  case ANALOG_MAPPING_QUERY: sendAnalogMappingResponse()
  case PIN_STATE_QUERY:      if dlen >= 1 { sendPinStateResponse(Int(data[0])) }
  case EXTENDED_ANALOG:      handleExtendedAnalog(data, dlen)
  case SAMPLING_INTERVAL:
    if dlen >= 2 {
      samplingInterval = UInt16(data[0] & 0x7F) | (UInt16(data[1] & 0x7F) << 7)
      if samplingInterval < MIN_SAMPLING { samplingInterval = MIN_SAMPLING }
    }
  case STRING_DATA:          handleString(data, dlen)
  case I2C_CONFIG:           handleI2CConfig(data, dlen)
  case I2C_REQUEST:          handleI2CRequest(data, dlen)
  case SCHEDULER_DATA:       schedHandleSysex(data, dlen)
  default:                   break
  }
}

// ===========================================================================
//  Input byte processor (Firmata state machine)
// ===========================================================================
func processByte(_ ps: inout ParserState, _ inputData: UInt8) {
  if ps.parsingSysex {
    if inputData == END_SYSEX {
      ps.parsingSysex = false
      processSysex(ps.sysexBuffer, ps.sysexBytesRead)
    } else if ps.sysexBytesRead < SYSEX_MAX {
      ps.sysexBuffer[ps.sysexBytesRead] = inputData; ps.sysexBytesRead += 1
    }
    return
  }

  if ps.waitForData > 0 && inputData < 0x80 {
    ps.waitForData -= 1
    ps.storedInputData[ps.waitForData] = inputData
    if ps.waitForData == 0 && ps.executeMultiByteCommand != 0 {
      switch ps.executeMultiByteCommand {
      case ANALOG_MESSAGE:
        handleAnalogMessage(Int(ps.multiByteChannel), ps.storedInputData[1], ps.storedInputData[0])
      case DIGITAL_MESSAGE:
        handleDigitalMessage(Int(ps.multiByteChannel), ps.storedInputData[1], ps.storedInputData[0])
      case SET_PIN_MODE:
        handleSetPinMode(Int(ps.storedInputData[1]), ps.storedInputData[0])
      case SET_DIGITAL_PIN_VALUE:
        handleSetDigitalPinValue(Int(ps.storedInputData[1]), ps.storedInputData[0])
      case REPORT_ANALOG:
        handleReportAnalog(Int(ps.multiByteChannel), ps.storedInputData[0])
      case REPORT_DIGITAL:
        handleReportDigital(Int(ps.multiByteChannel), ps.storedInputData[0])
      default: break
      }
      ps.executeMultiByteCommand = 0
    }
    return
  }

  // New command byte.
  var command: UInt8
  if inputData < 0xF0 {
    command = inputData & 0xF0
    ps.multiByteChannel = inputData & 0x0F
  } else {
    command = inputData
  }

  switch command {
  case ANALOG_MESSAGE, DIGITAL_MESSAGE, SET_PIN_MODE, SET_DIGITAL_PIN_VALUE:
    ps.waitForData = 2; ps.executeMultiByteCommand = command
  case REPORT_ANALOG, REPORT_DIGITAL:
    ps.waitForData = 1; ps.executeMultiByteCommand = command
  case START_SYSEX:
    ps.parsingSysex = true; ps.sysexBytesRead = 0
  case SYSTEM_RESET:
    systemResetState()
  case REPORT_VERSION:
    sendProtocolVersion()
  default:
    break
  }
}

// ===========================================================================
//  Firmata Scheduler (SysEx 0x7B)
// ===========================================================================
func schedFind(_ id: UInt8) -> SchedTask? {
  for i in 0..<MAX_TASKS where schedTasks[i].used && schedTasks[i].id == id { return schedTasks[i] }
  return nil
}

// Encoder7Bit decode: unpack `outBytes` 8-bit bytes from 7-bit `inp`.
func sched7BitDecode(_ outBytes: Int, _ inp: [UInt8], _ out: inout [UInt8]) {
  let inLen = inp.count
  for i in 0..<outBytes {
    let j = i << 3
    let pos = j / 7
    let shift = UInt8(j % 7)
    let lo = pos < inLen ? inp[pos] : 0
    let hi = (pos + 1) < inLen ? inp[pos + 1] : 0
    out[i] = (lo >> shift) | UInt8((UInt16(hi) << (7 - shift)) & 0xFF)
  }
}
func sched7BitOutBytes(_ encodedLen: Int) -> Int { (encodedLen * 7) >> 3 }

// Decode a 32-bit little-endian value from 5 Encoder7Bit-packed bytes.
func sched7BitTime(_ enc5: [UInt8]) -> UInt32 {
  var b = [UInt8](repeating: 0, count: 4)
  sched7BitDecode(4, enc5, &b)
  return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
}

func schedReset() {
  for i in 0..<MAX_TASKS { schedTasks[i].used = false }
  for i in 0..<NUM_SCHED_REGS { schedReg[i] = 0 }
  runningTask = nil
}

func schedSendError(_ id: UInt8) {
  sendFrame([START_SYSEX, SCHEDULER_DATA, SCHED_ERROR_REPLY, id, END_SYSEX], 5)
}

func schedCreate(_ id: UInt8, _ len: UInt16) {
  if schedFind(id) != nil || len > UInt16(MAX_TASK_BYTES) { schedSendError(id); return }
  for i in 0..<MAX_TASKS where !schedTasks[i].used {
    let t = schedTasks[i]
    t.used = true; t.id = id; t.time_ms = 0; t.len = len; t.pos = 0
    return
  }
  schedSendError(id)  // no free slot
}

func schedDelete(_ id: UInt8) {
  if let t = schedFind(id) { if runningTask === t { runningTask = nil }; t.used = false }
}

func schedAdd(_ id: UInt8, _ data: [UInt8], _ n: Int) {
  guard let t = schedFind(id) else { schedSendError(id); return }
  if Int(t.pos) + n > Int(t.len) { return }      // would overflow reserved length
  for i in 0..<n { t.data[Int(t.pos)] = data[i]; t.pos += 1 }
}

func schedSchedule(_ id: UInt8, _ delayMs: UInt32) {
  guard let t = schedFind(id) else { schedSendError(id); return }
  t.pos = 0
  t.time_ms = fm_millis() &+ delayMs
  if t.time_ms == 0 { t.time_ms = 1 }
}

func schedDelayRunning(_ delayMs: UInt32) {
  guard let t = runningTask else { return }
  let now = fm_millis()
  t.time_ms = t.time_ms &+ delayMs
  if Int32(bitPattern: t.time_ms &- now) < 0 { t.time_ms = now }
  if t.time_ms == 0 { t.time_ms = 1 }
}

func schedQueryAll() {
  var n = 0
  frameBuf[n] = START_SYSEX; n += 1; frameBuf[n] = SCHEDULER_DATA; n += 1; frameBuf[n] = SCHED_QUERY_ALL_REPLY; n += 1
  for i in 0..<MAX_TASKS where schedTasks[i].used { frameBuf[n] = schedTasks[i].id; n += 1 }
  frameBuf[n] = END_SYSEX; n += 1
  sendFrame(frameBuf, n)
}

// Encoder7Bit encode one byte into frameBuf, carrying state in shift/prev.
func sched7BitPut(_ n: inout Int, _ shift: inout UInt8, _ prev: inout UInt8, _ d: UInt8) {
  if shift == 0 {
    frameBuf[n] = d & 0x7F; n += 1; shift = 1; prev = d >> 7
  } else {
    frameBuf[n] = UInt8(((UInt16(d) << shift) & 0x7F) | UInt16(prev)); n += 1
    if shift == 6 { frameBuf[n] = d >> 1; n += 1; shift = 0 }
    else { shift += 1; prev = d >> (8 - shift) }
  }
}

func schedQueryTask(_ id: UInt8) {
  guard let t = schedFind(id) else { schedSendError(id); return }
  var n = 0
  frameBuf[n] = START_SYSEX; n += 1; frameBuf[n] = SCHEDULER_DATA; n += 1; frameBuf[n] = SCHED_QUERY_REPLY; n += 1
  frameBuf[n] = id; n += 1
  let header: [UInt8] = [
    UInt8(t.time_ms & 0xFF), UInt8((t.time_ms >> 8) & 0xFF),
    UInt8((t.time_ms >> 16) & 0xFF), UInt8((t.time_ms >> 24) & 0xFF),
    UInt8(t.len & 0xFF), UInt8((t.len >> 8) & 0xFF),
    UInt8(t.pos & 0xFF), UInt8((t.pos >> 8) & 0xFF)
  ]
  var shift: UInt8 = 0, prev: UInt8 = 0
  for i in 0..<8 { sched7BitPut(&n, &shift, &prev, header[i]) }
  var i = 0
  while i < Int(t.len) { sched7BitPut(&n, &shift, &prev, t.data[i]); i += 1 }
  if shift > 0 { frameBuf[n] = prev; n += 1 }
  frameBuf[n] = END_SYSEX; n += 1
  sendFrame(frameBuf, n)
}

// ---- NON-STANDARD scheduler logic extension (NONSTANDARD.md) ----
func schedCompare(_ op: UInt8, _ a: Int32, _ b: Int32) -> Bool {
  switch op {
  case 0: return a == b
  case 1: return a != b
  case 2: return a <  b
  case 3: return a >  b
  case 4: return a <= b
  case 5: return a >= b
  default: return false
  }
}

func schedReadOperand(_ payload: [UInt8], _ plen: Int, _ i: inout Int) -> Int32 {
  if i >= plen { return 0 }
  let type = payload[i]; i += 1
  if type == 0 {                     // register
    if i >= plen { return 0 }
    let r = schedReg[Int(payload[i] & 0x0F)]; i += 1; return r
  } else {                           // constant (5 Encoder7Bit bytes)
    if i + 5 > plen { i = plen; return 0 }
    let v = Int32(bitPattern: sched7BitTime(Array(payload[i..<i+5]))); i += 5; return v
  }
}

func schedSkip(_ skip: UInt16) {
  guard let t = runningTask else { return }
  let p = UInt32(t.pos) + UInt32(skip)
  t.pos = (p > UInt32(t.len)) ? t.len : UInt16(p)
}

func schedHandleExt(_ payload: [UInt8], _ plen: Int) {
  switch payload[0] {
  case SCHED_EXT_SET:                 // 0x10 reg <const:5>
    if plen == 7 { schedReg[Int(payload[1] & 0x0F)] = Int32(bitPattern: sched7BitTime(Array(payload[2..<7]))) }
  case SCHED_EXT_READ_DIGITAL:        // 0x11 reg pin
    if plen == 3 { schedReg[Int(payload[1] & 0x0F)] = (digitalRead(payload[2]) != 0) ? 1 : 0 }
  case SCHED_EXT_READ_ANALOG:         // 0x12 reg channel
    if plen == 3 {
      let pin = pinOfAnalogChannel(Int(payload[2]))
      schedReg[Int(payload[1] & 0x0F)] = (pin >= 0) ? Int32(analogRead(UInt8(pin))) : 0
    }
  case SCHED_EXT_IF:                  // 0x13 op <operandA> <operandB> skipLo skipHi
    var i = 1
    let op = payload[i]; i += 1
    let a = schedReadOperand(payload, plen, &i)
    let b = schedReadOperand(payload, plen, &i)
    if i + 2 > plen { break }
    let skip = UInt16(payload[i]) | (UInt16(payload[i + 1]) << 7)
    if !schedCompare(op, a, b) { schedSkip(skip) }
  case SCHED_EXT_SKIP:                // 0x14 skipLo skipHi
    if plen == 3 { schedSkip(UInt16(payload[1]) | (UInt16(payload[2]) << 7)) }
  default:
    break
  }
}

func schedHandleSysex(_ payload: [UInt8], _ plen: Int) {
  if plen < 1 { return }
  switch payload[0] {
  case SCHED_CREATE:
    if plen == 4 { schedCreate(payload[1], UInt16(payload[2]) | (UInt16(payload[3]) << 7)) }
  case SCHED_DELETE:
    if plen == 2 { schedDelete(payload[1]) }
  case SCHED_ADD:
    if plen > 2 {
      var outLen = sched7BitOutBytes(plen - 2)
      if outLen > MAX_TASK_BYTES { outLen = MAX_TASK_BYTES }
      var dec = [UInt8](repeating: 0, count: MAX_TASK_BYTES)
      sched7BitDecode(outLen, Array(payload[2..<plen]), &dec)
      schedAdd(payload[1], dec, outLen)
    }
  case SCHED_DELAY:
    if plen == 6 { schedDelayRunning(sched7BitTime(Array(payload[1..<6]))) }
  case SCHED_SCHEDULE:
    if plen == 7 { schedSchedule(payload[1], sched7BitTime(Array(payload[2..<7]))) }
  case SCHED_EXT_COMMAND:             // 0x7F: logic ops live under the reserved ext cmd
    if plen >= 2 { schedHandleExt(Array(payload[1..<plen]), plen - 1) }
  case SCHED_QUERY_ALL: schedQueryAll()
  case SCHED_QUERY:     if plen == 2 { schedQueryTask(payload[1]) }
  case SCHED_RESET:     schedReset()
  default: break
  }
}

// Replay a task until a delay reschedules it or it finishes. Returns true to keep it.
func schedExecute(_ t: SchedTask) -> Bool {
  let start = t.time_ms
  runningTask = t
  taskParser = ParserState()
  while t.pos < t.len {
    let b = t.data[Int(t.pos)]; t.pos += 1
    processByte(&taskParser, b)
    if t.time_ms != start {               // a DELAY_TASK fired
      if t.pos >= t.len { t.pos = 0 }      // trailing delay -> loop from start
      runningTask = nil
      return true
    }
  }
  runningTask = nil
  return false
}

func schedTick() {
  let now = fm_millis()
  for i in 0..<MAX_TASKS {
    let t = schedTasks[i]
    if t.used && t.time_ms != 0 && Int32(bitPattern: now &- t.time_ms) >= 0 {
      if !schedExecute(t) { t.used = false }
    }
  }
}

// ===========================================================================
//  Periodic sampling (device -> host)
// ===========================================================================
func checkDigitalInputs() {
  for port in 0..<NUM_PORTS {
    if !reportPort[port] { continue }
    var mask: UInt8 = 0
    for i in 0..<8 {
      let pin = port * 8 + i
      if pin >= TOTAL_PINS { break }
      if !isUsable(pin) || !pinConfigured[pin] { continue }
      let m = pinModes[pin]
      if m == PIN_MODE_INPUT || m == PIN_MODE_PULLUP {
        if digitalRead(UInt8(pin)) != 0 { mask |= (UInt8(1) << i) }
      } else if m == PIN_MODE_OUTPUT {
        if pinValues[pin] != 0 { mask |= (UInt8(1) << i) }
      }
    }
    if mask != previousPort[port] { previousPort[port] = mask; sendDigitalPort(port, mask) }
  }
}

func sampleAnalogAndI2C() {
  for ch in 0..<NUM_ANALOG where (analogReportMask & (UInt16(1) << ch)) != 0 {
    let pin = pinOfAnalogChannel(ch)
    if pin >= 0 { sendAnalogReport(ch, Int(analogRead(UInt8(pin)))) }
  }
  for i in 0..<MAX_CONT_READS where contReads[i].active {
    i2cDoRead(contReads[i].address, contReads[i].reg, contReads[i].count)
  }
}

// ===========================================================================
//  Reset
// ===========================================================================
func resetSessionState() {
  liveParser = ParserState()
  analogReportMask = 0
  for i in 0..<NUM_PORTS { reportPort[i] = false; previousPort[i] = 0 }
  for i in 0..<MAX_CONT_READS { contReads[i].active = false }
}

func systemResetState() {
  resetSessionState()
  taskParser = ParserState()
  schedReset()
  for pin in 0..<TOTAL_PINS {
    if isUsable(pin) { fm_pin_mode(Int32(pin), 0) }
    pinModes[pin] = PIN_MODE_INPUT
    pinValues[pin] = 0
    pinConfigured[pin] = false
  }
  samplingInterval = 19
}

func onNewConnection() {
  resetSessionState()
  sendProtocolVersion()
}

// Standard STRING_DATA "eviction notice" (0x01 + "EVICTED"), recognised by
// SwiftFirmataClient, sent to the outgoing master on a cross-transport handover.
func buildEvictionFrame() -> [UInt8] {
  let s: [UInt8] = [0x01, 69, 86, 73, 67, 84, 69, 68]   // \x01 "EVICTED"
  var out: [UInt8] = [START_SYSEX, STRING_DATA]
  for c in s { out.append(c & 0x7F); out.append((c >> 7) & 0x7F) }
  out.append(END_SYSEX)
  return out
}

// Make `who` the single board master, evicting the other transport's holder.
func claimMaster(_ who: UInt8) {
  if activeTransport != TR_NONE && activeTransport != who {
    let nb = buildEvictionFrame()
    sendFrame(nb, nb.count)        // routes to the OLD master (activeTransport not yet updated)
    fm_delay_ms(15)
  }
  if who != TR_TCP { fm_tcp_drop() }
  if who != TR_BLE { fm_ble_drop() }
  activeTransport = who
  onNewConnection()                // fresh session (keeps pins + scheduler tasks)
}

func transportConnected() -> Bool { activeTransport != TR_NONE }

// ===========================================================================
//  Periodic work (scheduler + sampling), run each loop iteration
// ===========================================================================
func loopTick() {
  schedTick()
  if transportConnected() {
    checkDigitalInputs()
    let now = fm_millis()
    if now &- lastSampleMs >= UInt32(samplingInterval) {
      lastSampleMs = now
      sampleAnalogAndI2C()
    }
  }
}

// ===========================================================================
//  User configuration
// ===========================================================================
let WIFI_SSID: StaticString = "YOUR_WIFI_SSID"
let WIFI_PASS: StaticString = "YOUR_WIFI_PASSWORD"
let MDNS_HOST: StaticString = "esp32-firmata"
let BLE_NAME:  StaticString = "Firmata-ESP32"
let TCP_PORT: Int32 = 3030

// StaticString is a null-terminated literal; pass its bytes as a C string.
@inline(__always) func cs(_ s: StaticString) -> UnsafePointer<UInt8> { s.utf8Start }

var wifiReady = false

// ===========================================================================
//  Transport — Wi-Fi / Bonjour (orchestration in Swift; vendor calls bridged)
// ===========================================================================
func startBonjour() {
  if fm_mdns_begin(cs(MDNS_HOST)) != 0 {
    fm_mdns_add_service(cs("firmata"), cs("tcp"), TCP_PORT)
    var ip = [UInt8](repeating: 0, count: 24)
    ip.withUnsafeMutableBufferPointer { _ = fm_wifi_localip($0.baseAddress, 24) }
    ip.withUnsafeBufferPointer { fm_mdns_add_txt(cs("firmata"), cs("tcp"), cs("ip"), $0.baseAddress) }
    fm_mdns_add_txt(cs("firmata"), cs("tcp"), cs("port"), cs("3030"))
    fm_log(cs("Bonjour: _firmata._tcp on :3030"))
  } else {
    fm_log(cs("mDNS start failed"))
  }
}

func startTcpServices() {
  startBonjour()
  fm_tcp_begin(TCP_PORT)
  wifiReady = true
  fm_log(cs("Wi-Fi up. IP ="))
  var ip = [UInt8](repeating: 0, count: 24)
  ip.withUnsafeMutableBufferPointer { _ = fm_wifi_localip($0.baseAddress, 24) }
  ip.withUnsafeBufferPointer { fm_log($0.baseAddress) }
}

func wifiStart() {
  fm_wifi_begin(cs(WIFI_SSID), cs(WIFI_PASS), cs(MDNS_HOST))
  fm_log(cs("Connecting to Wi-Fi..."))
  var tries = 0
  while fm_wifi_connected() == 0 && tries < 40 { fm_delay_ms(400); tries += 1 }
  if fm_wifi_connected() != 0 { startTcpServices() }
  else { fm_log(cs("Wi-Fi not up yet; BLE still available.")) }
}

func tcpPoll() {
  if fm_wifi_connected() == 0 {
    if wifiReady { wifiReady = false; fm_log(cs("Wi-Fi lost")) }
    return
  }
  if !wifiReady { startTcpServices() }
  if fm_tcp_poll_new() != 0 {                       // a new client is waiting
    if fm_tcp_connected() != 0 {                    // within-TCP replace: notify the old one
      let nb = buildEvictionFrame()
      nb.withUnsafeBufferPointer { fm_tcp_write($0.baseAddress, Int32(nb.count)) }
    }
    fm_tcp_promote()
    fm_log(cs("TCP client connected"))
    claimMaster(TR_TCP)
  }
  if fm_tcp_connected() == 0 && activeTransport == TR_TCP { activeTransport = TR_NONE }
  var g = 0
  while fm_tcp_connected() != 0 && fm_tcp_available() != 0 && g < 1024 {
    processByte(&liveParser, UInt8(fm_tcp_read() & 0xFF)); g += 1
  }
}

// ===========================================================================
//  Transport — BLE (orchestration in Swift; vendor events bridged via FIFO/flags)
// ===========================================================================
func bleSend(_ buf: [UInt8], _ len: Int) {
  let mtu = Int(fm_ble_mtu())
  let chunk = mtu > 23 ? mtu - 3 : 20
  buf.withUnsafeBufferPointer { bp in
    guard let base = bp.baseAddress else { return }
    var off = 0
    while off < len {
      let n = (len - off < chunk) ? (len - off) : chunk
      fm_ble_notify(base + off, Int32(n))
      off += n
      if off < len { fm_delay_ms(6) }
    }
  }
}

func blePoll() {
  if fm_ble_poll_connect() != 0 {
    fm_log(cs("BLE central connected")); claimMaster(TR_BLE)
  } else if fm_ble_poll_disconnect() != 0 {
    if activeTransport == TR_BLE { activeTransport = TR_NONE }
    fm_log(cs("BLE central disconnected"))
  }
  var g = 0
  var b = fm_ble_rx_pop()
  while b >= 0 && g < 4096 { processByte(&liveParser, UInt8(b & 0xFF)); g += 1; b = fm_ble_rx_pop() }
}

// ===========================================================================
//  Entry point — ESP-IDF app_main (C) calls sw_main(); Swift owns the run loop.
// ===========================================================================
@_cdecl("sw_main")
public func sw_main() {
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
    loopTick()
    fm_delay_ms(1)
  }
}
