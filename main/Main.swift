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
let FIRMWARE_NAME: StaticString = "swiftFirmataESP32"
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

// Encrypted Wi-Fi provisioning (non-standard; top-level user-range SysEx 0x0C).
let WIFI_CONFIG: UInt8 = 0x0C
let WC_SET:    UInt8 = 0x00   // host->dev: <clientPub><nonce><ciphertext+tag>
let WC_FORGET: UInt8 = 0x01   // host->dev: clear stored creds
let WC_QUERY:  UInt8 = 0x02   // host->dev: request status
let WC_BEGIN:  UInt8 = 0x03   // host->dev: start handshake
let WC_KEY:    UInt8 = 0x7E   // dev->host: <devicePub> (32 bytes)
let WC_STATUS: UInt8 = 0x7F   // dev->host: <code> <ipLen> <ip>  (0 down, 1 connected, 2 rejected)

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
let SCHED_EXT_HTTP_REPLY: UInt8  = 0x0B   // device -> host: status + response body

// Logic extension (NONSTANDARD.md) under EXTENDED_SCHEDULER_COMMAND (0x7F)
let SCHED_EXT_COMMAND: UInt8      = 0x7F
let SCHED_EXT_SET: UInt8          = 0x10
let SCHED_EXT_READ_DIGITAL: UInt8 = 0x11
let SCHED_EXT_READ_ANALOG: UInt8  = 0x12
let SCHED_EXT_IF: UInt8           = 0x13
let SCHED_EXT_SKIP: UInt8         = 0x14
let SCHED_EXT_HTTP: UInt8         = 0x15   // make an internet request from a task
// Response-inspection ops (operate on the last HTTP response body):
let SCHED_EXT_JSON_NUM: UInt8     = 0x16   // R[dst] = json number at <path> ×10^scale; R[found]=0/1
let SCHED_EXT_JSON_STR_EQ: UInt8  = 0x17   // R[dst] = (json string at <path> == <str>) ? 1 : 0
let SCHED_EXT_BODY_CONTAINS: UInt8 = 0x18  // R[dst] = body contains <str> ? 1 : 0
let SCHED_EXT_JSON_STR_CONTAINS: UInt8 = 0x19 // R[dst] = (json string at <path> contains <str>) ? 1 : 0
let SCHED_EXT_ARITH: UInt8        = 0x1A   // R[dst] = A <op> B  (op: 0+ 1- 2* 3/ 4%)
let SCHED_EXT_SET_FLOAT: UInt8    = 0x1B   // F[dst] = float const (IEEE754 bits in 5 bytes)
let SCHED_EXT_ARITH_FLOAT: UInt8      = 0x1C   // F[dst] = A <op> B (float; op 0+ 1- 2* 3/)
let SCHED_EXT_JSON_FLOAT: UInt8   = 0x1D   // F[dst] = json float at <path>; R[found]=0/1
let SCHED_EXT_JSON_TYPE: UInt8    = 0x1E   // R[dst] = type at <path> (0 none,1 obj,2 arr,3 str,4 num,5 bool,6 null)
let SCHED_EXT_JSON_SIZE: UInt8    = 0x1F   // R[dst] = byte length of value span at <path> (0 if none)
let SCHED_EXT_STR_LEN: UInt8      = 0x20   // R[dst] = content length of json string at <path> (0 if not string)
let SCHED_EXT_HEAP: UInt8         = 0x21   // R[freeReg]=free heap, R[largestReg]=largest free block
let SCHED_EXT_REQUEST_COUNT: UInt8     = 0x22   // R[dst] = current response generation (++ per request)
let SCHED_EXT_SNAPSHOT: UInt8     = 0x23   // copy value at <path> from live body into snapshot slot
let SCHED_EXT_SELECT: UInt8       = 0x24   // pick the inspection source (0=live, k=snapshot k-1)
let SCHED_EXT_FREE: UInt8         = 0x25   // free a snapshot slot
let SCHED_EXT_LAST_STATUS: UInt8  = 0x26   // R[dst] = status of the last inspection op
let SCHED_EXT_CMP: UInt8          = 0x27   // R[dst] = (A <op> B) ? 1 : 0  (op: 0== 1!= 2< 3> 4<= 5>=)

// Result-status codes (read with SCHED_EXT_LAST_STATUS).
let ST_OK: Int32            = 0
let ST_NOT_FOUND: Int32     = 1
let ST_STALE: Int32         = 2
let ST_TYPE_MISMATCH: Int32 = 3
let ST_TOO_BIG: Int32       = 4
let ST_ALLOC_FAILED: Int32  = 5
let NUM_SNAP = 2

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
let SYSEX_MAX = 512   // large enough for an HTTP op's URL + body in one SysEx

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

let NUM_SCHED_REGS = 16
let NUM_FLOAT_REGS = 8

// Live protocol handler, scheduler, and the dedicated handler for task replay.
// Their cross-references are wired once at startup in sw_main().
let scheduler     = Scheduler()
let liveHandler   = FirmataProtocol()
let replayHandler = FirmataProtocol()

// Scratch buffer used to build outgoing frames (sized for HTTP response bodies).
var frameBuf = [UInt8](repeating: 0, count: 2048)
// Max response bytes retained on-device for JSON/string inspection ops AND
// echoed back to a connected host (so the host can parse the full body).
let HTTP_PARSE_MAX = 4096

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
// ===========================================================================
//  I2C device helpers (shared by the live handler and periodic sampling)
// ===========================================================================
func i2cRead(_ address: UInt16, _ reg: Int, _ count0: UInt16) {
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

// ===========================================================================
//  Live protocol handler
//
//  Parses an incoming Firmata byte stream (its own ParserState) and applies
//  each command. One instance drives the live transport; a second instance
//  drives scheduler task replay. Both act on shared device state and route
//  scheduler SysEx to the shared `Scheduler`.
// ===========================================================================
final class FirmataProtocol {
  var ps = ParserState()
  var sched: Scheduler!            // wired once at startup (see sw_main)

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

  func handleI2CConfig(_ data: [UInt8], _ len: Int) {
    fm_i2c_begin(Int32(I2C_SDA_PIN), Int32(I2C_SCL_PIN))
    if len >= 2 { i2cReadDelayUs = UInt16(data[0] & 0x7F) | (UInt16(data[1] & 0x7F) << 7) }
  }

  func handleI2CRequest(_ data: [UInt8], _ len: Int) {
    if len < 2 { return }
    var address = UInt16(data[0] & 0x7F)
    let control = data[1]
    let mode = (control >> 3) & 0x03
    let tenbit = (control & 0x20) != 0
    if tenbit { address |= UInt16(control & 0x07) << 7 }

    let poff = 2
    let payloadLen = len - 2

    switch mode {
    case 0:  // WRITE
      fm_i2c_begin_transmission(Int32(address))
      var i = 0
      while i + 1 < payloadLen {
        let b = (data[poff + i] & 0x7F) | ((data[poff + i + 1] & 0x7F) << 7)
        fm_i2c_write(Int32(b)); i += 2
      }
      let restart = (control & 0x40) != 0
      _ = fm_i2c_end_transmission(restart ? 0 : 1)   // restart -> no STOP
    case 1:  // READ_ONCE
      var reg = -1; var count: UInt16 = 0
      if payloadLen >= 4 {
        reg   = Int(data[poff] & 0x7F) | (Int(data[poff + 1] & 0x7F) << 7)
        count = UInt16(data[poff + 2] & 0x7F) | (UInt16(data[poff + 3] & 0x7F) << 7)
      } else if payloadLen >= 2 {
        count = UInt16(data[poff] & 0x7F) | (UInt16(data[poff + 1] & 0x7F) << 7)
      }
        i2cRead(address, reg, count)
    case 2:  // READ_CONTINUOUS
      var reg = -1; var count: UInt16 = 0
      if payloadLen >= 4 {
        reg   = Int(data[poff] & 0x7F) | (Int(data[poff + 1] & 0x7F) << 7)
        count = UInt16(data[poff + 2] & 0x7F) | (UInt16(data[poff + 3] & 0x7F) << 7)
      } else if payloadLen >= 2 {
        count = UInt16(data[poff] & 0x7F) | (UInt16(data[poff + 1] & 0x7F) << 7)
      }
      addContinuousRead(address, reg, count)
    case 3:  // STOP_READING
      stopContinuousRead(address)
    default:
      break
    }
  }

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
    case SCHEDULER_DATA:       sched.handleSysex(data, dlen)
    case WIFI_CONFIG:          handleWiFiConfig(data, dlen)
    default:                   break
    }
  }

  // Firmata input byte state machine; mutates this handler's own ParserState.
  func process(_ inputData: UInt8) {
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
}

// ===========================================================================
//  Encoder7Bit helpers (8-bit data packed into 7-bit bytes), shared by the
//  Scheduler and used against the shared `frameBuf`.
// ===========================================================================
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
  var decoded = [UInt8](repeating: 0, count: 4)
  sched7BitDecode(4, enc5, &decoded)
  return UInt32(decoded[0]) | (UInt32(decoded[1]) << 8) | (UInt32(decoded[2]) << 16) | (UInt32(decoded[3]) << 24)
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

// ===========================================================================
//  Firmata Scheduler (SysEx 0x7B)
//
//  Stores tasks (recorded Firmata bytes + delays) and replays them — through a
//  dedicated FirmataProtocol instance (`replay`) — even with no host connected.
//  Also owns the non-standard logic extension (16 Int32 registers, if/else and
//  internet actions).
// ===========================================================================
final class Scheduler {
  var tasks: [SchedTask] = {
    var a: [SchedTask] = []
    for _ in 0..<MAX_TASKS { a.append(SchedTask()) }
    return a
  }()
  var running: SchedTask? = nil
  var regs = [Int32](repeating: 0, count: NUM_SCHED_REGS)
  var fregs = [Float](repeating: 0, count: NUM_FLOAT_REGS)
  var requestCount: Int32 = 0           // ++ on each HTTP request; basis for handle staleness (3b2)
  var inspectSel = 0               // inspection source: 0 = live body, k = snapshot slot k-1
  var inspectStale = false         // borrowed source selected after a newer request
  var lastStatus: Int32 = 0        // result-status of the last inspection op
  var replay: FirmataProtocol!     // wired once at startup (see sw_main)

  func find(_ id: UInt8) -> SchedTask? {
    for i in 0..<MAX_TASKS where tasks[i].used && tasks[i].id == id { return tasks[i] }
    return nil
  }

  func reset() {
    for i in 0..<MAX_TASKS { tasks[i].used = false }
    for i in 0..<NUM_SCHED_REGS { regs[i] = 0 }
    for i in 0..<NUM_FLOAT_REGS { fregs[i] = 0 }
    requestCount = 0
    inspectSel = 0; inspectStale = false; lastStatus = 0
    for s in 0..<NUM_SNAP { fm_snapshot_free(Int32(s)) }
    running = nil
  }

  func sendError(_ id: UInt8) {
    sendFrame([START_SYSEX, SCHEDULER_DATA, SCHED_ERROR_REPLY, id, END_SYSEX], 5)
  }

  func create(_ id: UInt8, _ len: UInt16) {
    if find(id) != nil || len > UInt16(MAX_TASK_BYTES) { sendError(id); return }
    for i in 0..<MAX_TASKS where !tasks[i].used {
      let t = tasks[i]
      t.used = true; t.id = id; t.time_ms = 0; t.len = len; t.pos = 0
      return
    }
    sendError(id)  // no free slot
  }

  func delete(_ id: UInt8) {
    if let t = find(id) { if running === t { running = nil }; t.used = false }
  }

  func add(_ id: UInt8, _ data: [UInt8], _ n: Int) {
    guard let t = find(id) else { sendError(id); return }
    if Int(t.pos) + n > Int(t.len) { return }      // would overflow reserved length
    for i in 0..<n { t.data[Int(t.pos)] = data[i]; t.pos += 1 }
  }

  func schedule(_ id: UInt8, _ delayMs: UInt32) {
    guard let t = find(id) else { sendError(id); return }
    t.pos = 0
    t.time_ms = fm_millis() &+ delayMs
    if t.time_ms == 0 { t.time_ms = 1 }
  }

  func delayRunning(_ delayMs: UInt32) {
    guard let t = running else { return }
    let now = fm_millis()
    t.time_ms = t.time_ms &+ delayMs
    if Int32(bitPattern: t.time_ms &- now) < 0 { t.time_ms = now }
    if t.time_ms == 0 { t.time_ms = 1 }
  }

  func queryAll() {
    var n = 0
    frameBuf[n] = START_SYSEX; n += 1; frameBuf[n] = SCHEDULER_DATA; n += 1; frameBuf[n] = SCHED_QUERY_ALL_REPLY; n += 1
    for i in 0..<MAX_TASKS where tasks[i].used { frameBuf[n] = tasks[i].id; n += 1 }
    frameBuf[n] = END_SYSEX; n += 1
    sendFrame(frameBuf, n)
  }

  func queryTask(_ id: UInt8) {
    guard let t = find(id) else { sendError(id); return }
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

  // ---- NON-STANDARD logic extension (NONSTANDARD.md) ----
  // An operand carries both an int and a float view; `isFloat` says which one is
  // authoritative (so a comparison promotes to float when either side is float).
  struct Operand { var isFloat: Bool; var i: Int32; var f: Float }

  // Trap-free Float → Int32 (NaN/overflow clamp).
  func f2i(_ x: Float) -> Int32 {
    if x.isNaN { return 0 }
    if x >= 2147483520.0 { return Int32.max }
    if x <= -2147483520.0 { return Int32.min }
    return Int32(x)
  }

  func compare(_ op: UInt8, _ a: Operand, _ b: Operand) -> Bool {
    if a.isFloat || b.isFloat {
      let x = a.f, y = b.f
      switch op {
      case 0: return x == y; case 1: return x != y; case 2: return x <  y
      case 3: return x >  y; case 4: return x <= y; case 5: return x >= y
      default: return false
      }
    }
    let x = a.i, y = b.i
    switch op {
    case 0: return x == y; case 1: return x != y; case 2: return x <  y
    case 3: return x >  y; case 4: return x <= y; case 5: return x >= y
    default: return false
    }
  }

  // Operand types: 00 int reg, 01 int const, 02 float reg, 03 float const.
  func readOperand(_ payload: [UInt8], _ payloadLen: Int, _ i: inout Int) -> Operand {
    if i >= payloadLen { return Operand(isFloat: false, i: 0, f: 0) }
    let type = payload[i]; i += 1
    switch type {
    case 0:                            // int register
      let v = (i < payloadLen) ? regs[Int(payload[i] & 0x0F)] : 0; i += 1
      return Operand(isFloat: false, i: v, f: Float(v))
    case 2:                            // float register
      let r = (i < payloadLen) ? fregs[Int(payload[i] & UInt8(NUM_FLOAT_REGS - 1))] : 0; i += 1
      return Operand(isFloat: true, i: f2i(r), f: r)
    case 3:                            // float constant (IEEE754 bits, 5 Encoder7Bit bytes)
      if i + 5 > payloadLen { i = payloadLen; return Operand(isFloat: false, i: 0, f: 0) }
      let fv = Float(bitPattern: sched7BitTime(Array(payload[i..<i+5]))); i += 5
      return Operand(isFloat: true, i: f2i(fv), f: fv)
    default:                           // 01 = int constant (5 Encoder7Bit bytes)
      if i + 5 > payloadLen { i = payloadLen; return Operand(isFloat: false, i: 0, f: 0) }
      let v = Int32(bitPattern: sched7BitTime(Array(payload[i..<i+5]))); i += 5
      return Operand(isFloat: false, i: v, f: Float(v))
    }
  }

  func skip(_ amount: UInt16) {
    guard let t = running else { return }
    let newPos = UInt32(t.pos) + UInt32(amount)
    t.pos = (newPos > UInt32(t.len)) ? t.len : UInt16(newPos)
  }

  func handleExt(_ payload: [UInt8], _ payloadLen: Int) {
    switch payload[0] {
    case SCHED_EXT_SET:                 // 0x10 reg <const:5>
      if payloadLen == 7 { regs[Int(payload[1] & 0x0F)] = Int32(bitPattern: sched7BitTime(Array(payload[2..<7]))) }
    case SCHED_EXT_READ_DIGITAL:        // 0x11 reg pin
      if payloadLen == 3 { regs[Int(payload[1] & 0x0F)] = (digitalRead(payload[2]) != 0) ? 1 : 0 }
    case SCHED_EXT_READ_ANALOG:         // 0x12 reg channel
      if payloadLen == 3 {
        let pin = pinOfAnalogChannel(Int(payload[2]))
        regs[Int(payload[1] & 0x0F)] = (pin >= 0) ? Int32(analogRead(UInt8(pin))) : 0
      }
    case SCHED_EXT_IF:                  // 0x13 op <operandA> <operandB> skipLo skipHi
      var i = 1
      let op = payload[i]; i += 1
      let a = readOperand(payload, payloadLen, &i)
      let b = readOperand(payload, payloadLen, &i)
      if i + 2 > payloadLen { break }
      let amount = UInt16(payload[i]) | (UInt16(payload[i + 1]) << 7)
      if !compare(op, a, b) { skip(amount) }
    case SCHED_EXT_SKIP:                // 0x14 skipLo skipHi
      if payloadLen == 3 { skip(UInt16(payload[1]) | (UInt16(payload[2]) << 7)) }
    case SCHED_EXT_HTTP:               // 0x15 internet request (see NONSTANDARD.md)
      http(payload, payloadLen)
    case SCHED_EXT_JSON_NUM:           // 0x16 dst found scale pathLo pathHi path…
      jsonNumber(payload, payloadLen)
    case SCHED_EXT_JSON_STR_EQ:        // 0x17 dst pathLo pathHi path… strLo strHi str…
      jsonString(payload, payloadLen, contains: false)
    case SCHED_EXT_BODY_CONTAINS:      // 0x18 dst strLo strHi str…
      bodyContains(payload, payloadLen)
    case SCHED_EXT_JSON_STR_CONTAINS:  // 0x19 dst pathLo pathHi path… strLo strHi str…
      jsonString(payload, payloadLen, contains: true)
    case SCHED_EXT_ARITH:              // 0x1A subop dst <operandA> <operandB>
      arith(payload, payloadLen)
    case SCHED_EXT_SET_FLOAT:          // 0x1B fdst <const:5>
      setFloat(payload, payloadLen)
    case SCHED_EXT_ARITH_FLOAT:            // 0x1C subop fdst <operandA> <operandB>
      arithFloat(payload, payloadLen)
    case SCHED_EXT_JSON_FLOAT:         // 0x1D fdst found pathLo pathHi path…
      jsonFloat(payload, payloadLen)
    case SCHED_EXT_JSON_TYPE:          // 0x1E dst pathLo pathHi path…
      jsonType(payload, payloadLen)
    case SCHED_EXT_JSON_SIZE:          // 0x1F dst pathLo pathHi path…
      jsonSize(payload, payloadLen)
    case SCHED_EXT_STR_LEN:            // 0x20 dst pathLo pathHi path…
      strLen(payload, payloadLen)
    case SCHED_EXT_HEAP:               // 0x21 freeReg largestReg
      heap(payload, payloadLen)
    case SCHED_EXT_REQUEST_COUNT:           // 0x22 dst
      readRequestCount(payload, payloadLen)
    case SCHED_EXT_SNAPSHOT:           // 0x23 slot pathLo pathHi path…
      snapshot(payload, payloadLen)
    case SCHED_EXT_SELECT:             // 0x24 sel expGenReg
      select(payload, payloadLen)
    case SCHED_EXT_FREE:               // 0x25 slot
      free(payload, payloadLen)
    case SCHED_EXT_LAST_STATUS:        // 0x26 dst
      lastStatus(payload, payloadLen)
    case SCHED_EXT_CMP:                // 0x27 op dst <operandA> <operandB>
      cmp(payload, payloadLen)
    default:
      break
    }
  }

  // ---- Internet action: a task (or a live host) makes an HTTP(S) request over
  //      the board's Wi-Fi. Layout of the ext payload:
  //        0x15 method statusReg urlLo urlHi url[urlLen] bodyLo bodyHi body[bodyLen]
  //      method 0=GET 1=POST. URL/body are raw ASCII (7-bit). On execution
  //      R[statusReg] = HTTP status (0 = Wi-Fi down / error); the full response
  //      body is retained for the inspection ops (JSON_NUM / *_STR_* / BODY_*).
  //      If a host is connected, status + body are also sent as SCHED_EXT_HTTP_REPLY.
  func http(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 5 { return }
    let method    = payload[1]
    let statusReg = Int(payload[2] & 0x0F)
    let urlLen    = Int(payload[3]) | (Int(payload[4]) << 7)
    var i = 5
    if urlLen <= 0 || i + urlLen > payloadLen { return }
    var url = [UInt8](repeating: 0, count: urlLen + 1)        // null-terminated
    for k in 0..<urlLen { url[k] = payload[i + k] }
    i += urlLen
    var bodyLen = 0
    if i + 2 <= payloadLen { bodyLen = Int(payload[i]) | (Int(payload[i + 1]) << 7); i += 2 }
    if bodyLen < 0 || i + bodyLen > payloadLen { bodyLen = 0 }
    var body = [UInt8](repeating: 0, count: bodyLen + 1)      // null-terminated
    for k in 0..<bodyLen { body[k] = payload[i + k] }

    let status = url.withUnsafeBufferPointer { up -> Int32 in
      body.withUnsafeBufferPointer { bp in
        Int32(fm_http_request(up.baseAddress, Int32(method == 1 ? 1 : 0),
                              bp.baseAddress, cs("application/json")))
      }
    }
    regs[statusReg] = status
    requestCount &+= 1                   // the retained body just changed (handle-staleness basis)
    if transportConnected() { sendHttpReply(Int(status)) }
  }

  // 0x22: R[dst] = current response generation (increments on every request).
  func readRequestCount(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 2 { return }
    regs[Int(payload[1] & 0x0F)] = requestCount
  }

  // ====== Response inspection — walks the selected source IN PLACE ======
  // Source is the live body (fm_http_resp_ptr) or a snapshot slot, chosen by
  // SELECT. Returns (ptr, len, stale) — `stale` is set when a borrowed (live)
  // source was selected against an out-of-date generation. Each op records a
  // result-status in `lastStatus` (read with SCHED_EXT_LAST_STATUS).
  func inspectBuf() -> (UnsafePointer<UInt8>?, Int, Bool) {
    if inspectSel == 0 { return (fm_http_resp_ptr(), Int(fm_http_resp_len()), inspectStale) }
    let s = Int32(inspectSel - 1)
    return (fm_snapshot_ptr(s), Int(fm_snapshot_len(s)), false)
  }

  // 0x16: R[dst] = number at JSON <path> × 10^scale (truncated); R[found] = 0/1.
  func jsonNumber(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 6 { return }
    let dst = Int(payload[1] & 0x0F), foundReg = Int(payload[2] & 0x0F), scale = Int(payload[3])
    let pathLen = Int(payload[4]) | (Int(payload[5]) << 7)
    if 6 + pathLen > payloadLen { return }
    let path = Array(payload[6..<6 + pathLen])
    regs[dst] = 0; regs[foundReg] = 0
    let (bOpt, bufLen, stale) = inspectBuf()
    if stale { lastStatus = ST_STALE; return }
    guard bufLen > 0, let buf = bOpt else { lastStatus = ST_NOT_FOUND; return }
    guard let (s, _) = jsonValueSpan(buf, bufLen, path) else { lastStatus = ST_NOT_FOUND; return }
    guard let v = parseScaledNumber(buf, bufLen, s, scale) else { lastStatus = ST_TYPE_MISMATCH; return }
    regs[dst] = v; regs[foundReg] = 1; lastStatus = ST_OK
  }

  // 0x17 (eq) / 0x19 (contains): compare JSON string at <path> with <str>.
  func jsonString(_ payload: [UInt8], _ payloadLen: Int, contains: Bool) {
    if payloadLen < 4 { return }
    let dst = Int(payload[1] & 0x0F)
    let pathLen = Int(payload[2]) | (Int(payload[3]) << 7)
    var i = 4 + pathLen
    if i + 2 > payloadLen { return }
    let path = Array(payload[4..<4 + pathLen])
    let strLen = Int(payload[i]) | (Int(payload[i + 1]) << 7); i += 2
    if i + strLen > payloadLen { return }
    let needle = Array(payload[i..<i + strLen])
    regs[dst] = 0
    let (bOpt, bufLen, stale) = inspectBuf()
    if stale { lastStatus = ST_STALE; return }
    guard bufLen > 0, let buf = bOpt else { lastStatus = ST_NOT_FOUND; return }
    guard let (s, e) = jsonValueSpan(buf, bufLen, path) else { lastStatus = ST_NOT_FOUND; return }
    guard s < e, buf[s] == 0x22 else { lastStatus = ST_TYPE_MISMATCH; return }
    let cs = s + 1, ce = e - 1                   // content between the quotes (escapes raw)
    if ce >= cs {
      regs[dst] = (contains ? bytesContain(buf, cs, ce, needle)
                            : bytesEqual(buf, cs, ce, needle)) ? 1 : 0
    }
    lastStatus = ST_OK
  }

  // 0x18: R[dst] = whole body contains <str> ? 1 : 0.
  func bodyContains(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 4 { return }
    let dst = Int(payload[1] & 0x0F)
    let strLen = Int(payload[2]) | (Int(payload[3]) << 7)
    if 4 + strLen > payloadLen { return }
    let needle = Array(payload[4..<4 + strLen])
    regs[dst] = 0
    let (bOpt, bufLen, stale) = inspectBuf()
    if stale { lastStatus = ST_STALE; return }
    guard bufLen > 0, let buf = bOpt else { lastStatus = ST_NOT_FOUND; return }
    regs[dst] = bytesContain(buf, 0, bufLen, needle) ? 1 : 0; lastStatus = ST_OK
  }

  // 0x1A: integer arithmetic. R[dst] = A <op> B  (op: 0+ 1- 2* 3/ 4%).
  // 64-bit intermediates avoid overflow traps; ÷ / % by zero yield 0.
  func arith(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 3 { return }
    let sub = payload[1], dst = Int(payload[2] & 0x0F)
    var i = 3
    let a = readOperand(payload, payloadLen, &i).i
    let b = readOperand(payload, payloadLen, &i).i
    var r: Int32 = 0
    switch sub {
    case 0: r = a &+ b
    case 1: r = a &- b
    case 2: r = Int32(truncatingIfNeeded: Int64(a) &* Int64(b))
    case 3: r = (b != 0) ? Int32(truncatingIfNeeded: Int64(a) / Int64(b)) : 0
    case 4: r = (b != 0) ? Int32(truncatingIfNeeded: Int64(a) % Int64(b)) : 0
    default: r = 0
    }
    regs[dst] = r
  }

  // 0x27: comparison. R[dst] = (A <op> B) ? 1 : 0  (op: 0== 1!= 2< 3> 4<= 5>=).
  // Reuses the same operand decoding + float-promoting compare as SCHED_EXT_IF, so a
  // task can materialise a reusable boolean register instead of branching inline.
  func cmp(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 3 { return }
    let op = payload[1], dst = Int(payload[2] & 0x0F)
    var i = 3
    let a = readOperand(payload, payloadLen, &i)
    let b = readOperand(payload, payloadLen, &i)
    regs[dst] = compare(op, a, b) ? 1 : 0
  }

  // 0x1C: float arithmetic. F[dst] = A <op> B  (op: 0+ 1- 2* 3/). ÷0 → 0.
  func arithFloat(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 3 { return }
    let sub = payload[1], dst = Int(payload[2] & UInt8(NUM_FLOAT_REGS - 1))
    var i = 3
    let a = readOperand(payload, payloadLen, &i).f
    let b = readOperand(payload, payloadLen, &i).f
    var r: Float = 0
    switch sub {
    case 0: r = a + b
    case 1: r = a - b
    case 2: r = a * b
    case 3: r = (b != 0) ? a / b : 0
    default: r = 0
    }
    fregs[dst] = r
  }

  // 0x1B: F[dst] = float constant (IEEE754 bits in 5 Encoder7Bit bytes).
  func setFloat(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen != 7 { return }
    fregs[Int(payload[1] & UInt8(NUM_FLOAT_REGS - 1))] = Float(bitPattern: sched7BitTime(Array(payload[2..<7])))
  }

  // 0x1D: F[dst] = json float at <path>; R[found] = 0/1.
  func jsonFloat(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 5 { return }
    let dst = Int(payload[1] & UInt8(NUM_FLOAT_REGS - 1)), foundReg = Int(payload[2] & 0x0F)
    let pathLen = Int(payload[3]) | (Int(payload[4]) << 7)
    if 5 + pathLen > payloadLen { return }
    let path = Array(payload[5..<5 + pathLen])
    fregs[dst] = 0; regs[foundReg] = 0
    let (bOpt, bufLen, stale) = inspectBuf()
    if stale { lastStatus = ST_STALE; return }
    guard bufLen > 0, let buf = bOpt else { lastStatus = ST_NOT_FOUND; return }
    guard let (s, _) = jsonValueSpan(buf, bufLen, path) else { lastStatus = ST_NOT_FOUND; return }
    guard let v = parseFloat(buf, bufLen, s) else { lastStatus = ST_TYPE_MISMATCH; return }
    fregs[dst] = v; regs[foundReg] = 1; lastStatus = ST_OK
  }

  // ---- Query ops: inspect a value's type/size before extracting/storing it ----
  // Returns the (dst, path) common to the query ops, plus the body span, or nil.
  private func queryArgs(_ payload: [UInt8], _ payloadLen: Int) -> (Int, UnsafePointer<UInt8>, Int, [UInt8])? {
    if payloadLen < 4 { return nil }
    let dst = Int(payload[1] & 0x0F)
    let pathLen = Int(payload[2]) | (Int(payload[3]) << 7)
    if 4 + pathLen > payloadLen { return nil }
    let path = Array(payload[4..<4 + pathLen])
    regs[dst] = 0
    let (bOpt, bufLen, stale) = inspectBuf()
    if stale { lastStatus = ST_STALE; return nil }
    guard bufLen > 0, let buf = bOpt else { lastStatus = ST_NOT_FOUND; return nil }
    return (dst, buf, bufLen, path)
  }
  // 0x1E: R[dst] = JSON type at path (0 none,1 obj,2 arr,3 str,4 num,5 bool,6 null).
  func jsonType(_ payload: [UInt8], _ payloadLen: Int) {
    guard let (dst, buf, bufLen, path) = queryArgs(payload, payloadLen) else { return }
    guard let (s, e) = jsonValueSpan(buf, bufLen, path), s < e else { lastStatus = ST_NOT_FOUND; return }
    let c = buf[s]
    var t: Int32 = 0
    if c == 0x7B { t = 1 }                                   // {
    else if c == 0x5B { t = 2 }                              // [
    else if c == 0x22 { t = 3 }                              // "
    else if (c >= 48 && c <= 57) || c == 0x2D { t = 4 }      // digit or -
    else if c == 0x74 || c == 0x66 { t = 5 }                // true/false
    else if c == 0x6E { t = 6 }                             // null
    regs[dst] = t; lastStatus = ST_OK
  }
  // 0x1F: R[dst] = byte length of the value span at path (for sizing a snapshot).
  func jsonSize(_ payload: [UInt8], _ payloadLen: Int) {
    guard let (dst, buf, bufLen, path) = queryArgs(payload, payloadLen) else { return }
    if let (s, e) = jsonValueSpan(buf, bufLen, path) { regs[dst] = Int32(e - s); lastStatus = ST_OK }
    else { regs[dst] = 0; lastStatus = ST_NOT_FOUND }
  }
  // 0x20: R[dst] = content length of the JSON string at path (0 if not a string).
  func strLen(_ payload: [UInt8], _ payloadLen: Int) {
    guard let (dst, buf, bufLen, path) = queryArgs(payload, payloadLen) else { return }
    guard let (s, e) = jsonValueSpan(buf, bufLen, path) else { regs[dst] = 0; lastStatus = ST_NOT_FOUND; return }
    if e - s >= 2, buf[s] == 0x22 { regs[dst] = Int32(e - s - 2); lastStatus = ST_OK }   // between quotes
    else { regs[dst] = 0; lastStatus = ST_TYPE_MISMATCH }
  }
  // 0x23: copy the value at <path> from the LIVE body into snapshot slot <slot>.
  func snapshot(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 4 { return }
    let slot = Int(payload[1]); if slot < 0 || slot >= NUM_SNAP { return }
    let pathLen = Int(payload[2]) | (Int(payload[3]) << 7)
    if 4 + pathLen > payloadLen { return }
    let path = Array(payload[4..<4 + pathLen])
    let bufLen = Int(fm_http_resp_len())
    guard bufLen > 0, let buf = fm_http_resp_ptr() else { lastStatus = ST_NOT_FOUND; return }
    guard let (s, e) = jsonValueSpan(buf, bufLen, path), e > s else { lastStatus = ST_NOT_FOUND; return }
    let ok = Int(fm_snapshot_copy(Int32(slot), buf + s, Int32(e - s)))
    lastStatus = (ok != 0) ? ST_OK : ST_ALLOC_FAILED
  }
  // 0x24: select the inspection source — 0 = live body (stale if requestCount != R[expGenReg]),
  //       k = snapshot slot k-1 (always valid).
  func select(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 3 { return }
    inspectSel = Int(payload[1])
    if inspectSel == 0 { inspectStale = (requestCount != regs[Int(payload[2] & 0x0F)]) }
    else { inspectStale = false }
  }
  // 0x25: free snapshot slot <slot>.
  func free(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 2 { return }
    let slot = Int(payload[1]); if slot >= 0 && slot < NUM_SNAP { fm_snapshot_free(Int32(slot)) }
  }
  // 0x26: R[dst] = status of the last inspection op.
  func lastStatus(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 2 { return }
    regs[Int(payload[1] & 0x0F)] = lastStatus
  }
  // 0x21: R[freeReg] = free heap, R[largestReg] = largest free block.
  func heap(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 3 { return }
    regs[Int(payload[1] & 0x0F)] = Int32(truncatingIfNeeded: fm_free_heap())
    regs[Int(payload[2] & 0x0F)] = Int32(truncatingIfNeeded: fm_largest_free_block())
  }

  // ---- minimal JSON walker over a raw byte buffer (no copy, no Foundation) ----
  private func jsonSkipWs(_ buf: UnsafePointer<UInt8>, _ bufLen: Int, _ i: Int) -> Int {
    var j = i
    while j < bufLen, buf[j] == 32 || buf[j] == 9 || buf[j] == 10 || buf[j] == 13 { j += 1 }
    return j
  }
  private func jsonSkipString(_ buf: UnsafePointer<UInt8>, _ bufLen: Int, _ i: Int) -> Int {  // i at opening quote
    var j = i + 1
    while j < bufLen {
      if buf[j] == 0x5C { j += 2; continue }   // backslash escape
      if buf[j] == 0x22 { return j + 1 }
      j += 1
    }
    return j
  }
  private func jsonSkipValue(_ buf: UnsafePointer<UInt8>, _ bufLen: Int, _ i: Int) -> Int {
    let j = jsonSkipWs(buf, bufLen, i)
    if j >= bufLen { return j }
    let c = buf[j]
    if c == 0x22 { return jsonSkipString(buf, bufLen, j) }
    if c == 0x7B || c == 0x5B {               // { or [
      let open = c, close: UInt8 = (c == 0x7B) ? 0x7D : 0x5D
      var k = j + 1, depth = 1
      while k < bufLen, depth > 0 {
        let d = buf[k]
        if d == 0x22 { k = jsonSkipString(buf, bufLen, k); continue }
        if d == open { depth += 1 } else if d == close { depth -= 1 }
        k += 1
      }
      return k
    }
    var k = j                                 // number / true / false / null
    while k < bufLen {
      let d = buf[k]
      if d == 0x2C || d == 0x7D || d == 0x5D || d == 32 || d == 9 || d == 10 || d == 13 { break }
      k += 1
    }
    return k
  }
  private func jsonObjectMember(_ buf: UnsafePointer<UInt8>, _ bufLen: Int, _ pos: Int, _ key: [UInt8]) -> Int? {
    var j = jsonSkipWs(buf, bufLen, pos)
    if j >= bufLen || buf[j] != 0x7B { return nil }
    j += 1
    while true {
      j = jsonSkipWs(buf, bufLen, j)
      if j >= bufLen || buf[j] == 0x7D { return nil }
      if buf[j] != 0x22 { return nil }
      let ks = j + 1
      let after = jsonSkipString(buf, bufLen, j); let ke = after - 1
      var match = (ke - ks) == key.count
      if match { for t in 0..<key.count where buf[ks + t] != key[t] { match = false; break } }
      j = jsonSkipWs(buf, bufLen, after)
      if j >= bufLen || buf[j] != 0x3A { return nil }       // ':'
      j = jsonSkipWs(buf, bufLen, j + 1)
      if match { return j }
      j = jsonSkipWs(buf, bufLen, jsonSkipValue(buf, bufLen, j))
      if j < bufLen, buf[j] == 0x2C { j += 1; continue }
      return nil
    }
  }
  private func jsonArrayElement(_ buf: UnsafePointer<UInt8>, _ bufLen: Int, _ pos: Int, _ idx: Int) -> Int? {
    var j = jsonSkipWs(buf, bufLen, pos)
    if j >= bufLen || buf[j] != 0x5B { return nil }
    j += 1
    var cur = 0
    while true {
      j = jsonSkipWs(buf, bufLen, j)
      if j >= bufLen || buf[j] == 0x5D { return nil }
      if cur == idx { return j }
      j = jsonSkipWs(buf, bufLen, jsonSkipValue(buf, bufLen, j))
      if j < bufLen, buf[j] == 0x2C { j += 1; cur += 1; continue }
      return nil
    }
  }
  // Resolve a dotted/indexed path (e.g. "a.buf[0].c") to the value's byte span.
  func jsonValueSpan(_ buf: UnsafePointer<UInt8>, _ bufLen: Int, _ path: [UInt8]) -> (Int, Int)? {
    if bufLen == 0 { return nil }
    var pos = jsonSkipWs(buf, bufLen, 0)
    var pi = 0
    while true {
      if pi >= path.count { return (pos, jsonSkipValue(buf, bufLen, pos)) }
      if path[pi] == 0x2E { pi += 1; continue }              // '.'
      if path[pi] == 0x5B {                                  // '[' index
        pi += 1; var idx = 0
        while pi < path.count, path[pi] >= 48, path[pi] <= 57 { idx = idx * 10 + Int(path[pi] - 48); pi += 1 }
        if pi < path.count, path[pi] == 0x5D { pi += 1 }
        guard let p2 = jsonArrayElement(buf, bufLen, pos, idx) else { return nil }
        pos = p2
      } else {                                               // object key
        let ks = pi
        while pi < path.count, path[pi] != 0x2E, path[pi] != 0x5B { pi += 1 }
        guard let p2 = jsonObjectMember(buf, bufLen, pos, Array(path[ks..<pi])) else { return nil }
        pos = p2
      }
    }
  }
  // Parse a JSON number — or a quoted number string "593.2" — at buf[i0] into
  // value × 10^scale (truncated). nil if not a number.
  func parseScaledNumber(_ buf: UnsafePointer<UInt8>, _ bufLen: Int, _ i0: Int, _ scale: Int) -> Int32? {
    var i = jsonSkipWs(buf, bufLen, i0)
    if i < bufLen, buf[i] == 0x22 { i += 1 }                     // tolerate a quoted number
    if i >= bufLen { return nil }
    var neg = false
    if buf[i] == 0x2D { neg = true; i += 1 }                   // '-'
    var intPart = 0, anyInt = false
    while i < bufLen, buf[i] >= 48, buf[i] <= 57 { intPart = intPart &* 10 &+ Int(buf[i] - 48); anyInt = true; i += 1 }
    if !anyInt { return nil }
    var fracDigits = [UInt8]()
    if i < bufLen, buf[i] == 0x2E {                              // '.'
      i += 1
      while i < bufLen, buf[i] >= 48, buf[i] <= 57 { fracDigits.append(buf[i] - 48); i += 1 }
    }
    var v = intPart
    for s in 0..<scale {                                     // shift in `scale` frac digits
      v = v &* 10 &+ (s < fracDigits.count ? Int(fracDigits[s]) : 0)
    }
    return Int32(truncatingIfNeeded: neg ? -v : v)
  }
  // 10^e as Float, by bounded repeated multiply (no libm dependency).
  private func pow10f(_ e: Int) -> Float {
    var r: Float = 1, n = e
    if n >= 0 { while n > 0 { r *= 10; n -= 1 } } else { while n < 0 { r /= 10; n += 1 } }
    return r
  }
  // Parse a JSON number — or quoted "593.2", with optional exponent — into a Float.
  func parseFloat(_ buf: UnsafePointer<UInt8>, _ bufLen: Int, _ i0: Int) -> Float? {
    var i = jsonSkipWs(buf, bufLen, i0)
    if i < bufLen, buf[i] == 0x22 { i += 1 }                     // tolerate a quoted number
    if i >= bufLen { return nil }
    var neg = false
    if buf[i] == 0x2D { neg = true; i += 1 }
    var v: Float = 0, anyInt = false
    while i < bufLen, buf[i] >= 48, buf[i] <= 57 { v = v * 10 + Float(buf[i] - 48); anyInt = true; i += 1 }
    if !anyInt { return nil }
    if i < bufLen, buf[i] == 0x2E {                              // fractional part
      i += 1
      var scale: Float = 1
      while i < bufLen, buf[i] >= 48, buf[i] <= 57 { v = v * 10 + Float(buf[i] - 48); scale *= 10; i += 1 }
      v /= scale
    }
    if neg { v = -v }
    if i < bufLen, (buf[i] == 0x65 || buf[i] == 0x45) {           // exponent e/E
      i += 1
      var eneg = false
      if i < bufLen, (buf[i] == 0x2B || buf[i] == 0x2D) { eneg = (buf[i] == 0x2D); i += 1 }
      var e = 0
      while i < bufLen, buf[i] >= 48, buf[i] <= 57 { e = e * 10 + Int(buf[i] - 48); i += 1 }
      v *= pow10f(eneg ? -e : e)
    }
    return v
  }
  private func bytesEqual(_ buf: UnsafePointer<UInt8>, _ s: Int, _ e: Int, _ needle: [UInt8]) -> Bool {
    if e - s != needle.count { return false }
    for t in 0..<needle.count where buf[s + t] != needle[t] { return false }
    return true
  }
  private func bytesContain(_ buf: UnsafePointer<UInt8>, _ s: Int, _ e: Int, _ needle: [UInt8]) -> Bool {
    if needle.isEmpty { return true }
    if e - s < needle.count { return false }
    var i = s
    while i <= e - needle.count {
      var m = true
      for t in 0..<needle.count where buf[i + t] != needle[t] { m = false; break }
      if m { return true }
      i += 1
    }
    return false
  }

  // Send the last HTTP result (status + body) to the connected host.
  func sendHttpReply(_ status: Int) {
    var rlen = Int(fm_http_resp_len())
    if rlen > HTTP_PARSE_MAX { rlen = HTTP_PARSE_MAX }
    // Dedicated buffer (frameBuf is only 2 KB): header + body as 14-bit pairs.
    var out = [UInt8](repeating: 0, count: rlen * 2 + 8)
    var n = 0
    out[n] = START_SYSEX;          n += 1
    out[n] = SCHEDULER_DATA;       n += 1
    out[n] = SCHED_EXT_HTTP_REPLY; n += 1
    out[n] = UInt8(status & 0x7F);        n += 1
    out[n] = UInt8((status >> 7) & 0x7F); n += 1
    if rlen > 0 {
      var rb = [UInt8](repeating: 0, count: rlen)
      let got = Int(rb.withUnsafeMutableBufferPointer { fm_http_resp_copy($0.baseAddress, Int32(rlen)) })
      for k in 0..<got {                 // 14-bit LSB/MSB pairs (like STRING_DATA)
        out[n] = rb[k] & 0x7F;        n += 1
        out[n] = (rb[k] >> 7) & 0x7F; n += 1
      }
    }
    out[n] = END_SYSEX; n += 1
    sendFrame(out, n)
  }

  func handleSysex(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 1 { return }
    switch payload[0] {
    case SCHED_CREATE:
      if payloadLen == 4 { create(payload[1], UInt16(payload[2]) | (UInt16(payload[3]) << 7)) }
    case SCHED_DELETE:
      if payloadLen == 2 { delete(payload[1]) }
    case SCHED_ADD:
      if payloadLen > 2 {
        var outLen = sched7BitOutBytes(payloadLen - 2)
        if outLen > MAX_TASK_BYTES { outLen = MAX_TASK_BYTES }
        var dec = [UInt8](repeating: 0, count: MAX_TASK_BYTES)
        sched7BitDecode(outLen, Array(payload[2..<payloadLen]), &dec)
        add(payload[1], dec, outLen)
      }
    case SCHED_DELAY:
      if payloadLen == 6 { delayRunning(sched7BitTime(Array(payload[1..<6]))) }
    case SCHED_SCHEDULE:
      if payloadLen == 7 { schedule(payload[1], sched7BitTime(Array(payload[2..<7]))) }
    case SCHED_EXT_COMMAND:             // 0x7F: logic ops live under the reserved ext cmd
      if payloadLen >= 2 { handleExt(Array(payload[1..<payloadLen]), payloadLen - 1) }
    case SCHED_QUERY_ALL: queryAll()
    case SCHED_QUERY:     if payloadLen == 2 { queryTask(payload[1]) }
    case SCHED_RESET:     reset()
    default: break
    }
  }

  // Replay a task until a delay reschedules it or it finishes. Returns true to keep it.
  func execute(_ t: SchedTask) -> Bool {
    let start = t.time_ms
    running = t
    replay.ps = ParserState()
    while t.pos < t.len {
      let b = t.data[Int(t.pos)]; t.pos += 1
      replay.process(b)
      if t.time_ms != start {               // a DELAY_TASK fired
        if t.pos >= t.len { t.pos = 0 }      // trailing delay -> loop from start
        running = nil
        return true
      }
    }
    running = nil
    return false
  }

  func tick() {
    let now = fm_millis()
    for i in 0..<MAX_TASKS {
      let t = tasks[i]
      if t.used && t.time_ms != 0 && Int32(bitPattern: now &- t.time_ms) >= 0 {
        if !execute(t) { t.used = false }
      }
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
      i2cRead(contReads[i].address, contReads[i].reg, contReads[i].count)
  }
}

// ===========================================================================
//  Reset
// ===========================================================================
func resetSessionState() {
  liveHandler.ps = ParserState()
  analogReportMask = 0
  for i in 0..<NUM_PORTS { reportPort[i] = false; previousPort[i] = 0 }
  for i in 0..<MAX_CONT_READS { contReads[i].active = false }
}

func systemResetState() {
  resetSessionState()
  replayHandler.ps = ParserState()
  scheduler.reset()
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
  scheduler.tick()
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

// Active Wi-Fi creds (null-terminated C strings): NVS-provisioned creds override
// the compile-time WIFI_SSID/WIFI_PASS. Loaded once before the first connect.
var gSsid = [UInt8](repeating: 0, count: 64)
var gPass = [UInt8](repeating: 0, count: 64)

@inline(__always) func copyStatic(_ s: StaticString, into buf: inout [UInt8]) {
  s.withUTF8Buffer { src in
    let n = min(src.count, buf.count - 1)
    for i in 0..<n { buf[i] = src[i] }
    buf[n] = 0
  }
}

func loadWifiCreds() {
  let found = gSsid.withUnsafeMutableBufferPointer { sp in
    gPass.withUnsafeMutableBufferPointer { pp in
      fm_nvs_load_creds(sp.baseAddress, 64, pp.baseAddress, 64)
    }
  }
  if found == 0 {                       // nothing provisioned → compile-time defaults
    copyStatic(WIFI_SSID, into: &gSsid)
    copyStatic(WIFI_PASS, into: &gPass)
  }
}

// (Re)connect Wi-Fi with the active creds; restart Bonjour/TCP on success.
func applyActiveCreds() -> Bool {
  // Already on the target network? Don't tear down a working link (also lets a
  // re-provision over TCP reply before the socket would drop).
  let same = gSsid.withUnsafeBufferPointer { sp in
    gPass.withUnsafeBufferPointer { pp in fm_wifi_same_network(sp.baseAddress, pp.baseAddress) }
  }
  if same != 0 { if !wifiReady { startTcpServices() }; return true }
  wifiReady = false
  gSsid.withUnsafeBufferPointer { sp in
    gPass.withUnsafeBufferPointer { pp in
      fm_wifi_begin(sp.baseAddress, pp.baseAddress, cs(MDNS_HOST))
    }
  }
  var tries = 0
  while fm_wifi_connected() == 0 && tries < 30 { fm_delay_ms(400); tries += 1 }
  if fm_wifi_connected() != 0 { startTcpServices(); return true }
  return false
}

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
  loadWifiCreds()                       // NVS-provisioned creds override compile-time
  fm_log(cs("Connecting to Wi-Fi..."))
  if !applyActiveCreds() { fm_log(cs("Wi-Fi not up yet; BLE still available.")) }
}

// ---- Encrypted Wi-Fi provisioning handler (WIFI_CONFIG SysEx 0x0C) ----------
func wcSendKey(_ pub: [UInt8]) {
  var out: [UInt8] = [START_SYSEX, WIFI_CONFIG, WC_KEY]
  for b in pub { out.append(b & 0x7F); out.append((b >> 7) & 0x01) }
  out.append(END_SYSEX)
  sendFrame(out, out.count)
}

// code: 0 = Wi-Fi down, 1 = connected, 2 = creds rejected (decrypt/auth failed).
func wcSendStatus(_ code: UInt8) {
  var out: [UInt8] = [START_SYSEX, WIFI_CONFIG, WC_STATUS, code]
  var ipbuf = [UInt8](repeating: 0, count: 24)
  let iplen = ipbuf.withUnsafeMutableBufferPointer { fm_wifi_localip($0.baseAddress, 24) }
  let n = (fm_wifi_connected() != 0) ? min(Int(iplen), 23) : 0
  out.append(UInt8(n & 0x7F))
  for i in 0..<n { out.append(ipbuf[i] & 0x7F); out.append((ipbuf[i] >> 7) & 0x01) }
  out.append(END_SYSEX)
  sendFrame(out, out.count)
}

func handleWiFiConfig(_ data: [UInt8], _ dlen: Int) {
  if dlen < 1 { return }
  switch data[0] {
  case WC_BEGIN:
    var pub = [UInt8](repeating: 0, count: 32)
    let ok = pub.withUnsafeMutableBufferPointer { fm_wc_begin($0.baseAddress) }
    if ok != 0 { wcSendKey(pub) }
  case WC_QUERY:
    wcSendStatus(fm_wifi_connected() != 0 ? 1 : 0)
  case WC_FORGET:
    fm_nvs_clear_creds()
    copyStatic(WIFI_SSID, into: &gSsid); copyStatic(WIFI_PASS, into: &gPass)
    wcSendStatus(fm_wifi_connected() != 0 ? 1 : 0)
  case WC_SET:
    // decode 14-bit LSB/MSB pairs -> raw: clientPub(32) nonce(12) ciphertext+tag
    var raw = [UInt8](); raw.reserveCapacity((dlen - 1) / 2)
    var i = 1
    while i + 1 < dlen { raw.append((data[i] & 0x7F) | ((data[i + 1] & 0x01) << 7)); i += 2 }
    if raw.count < 32 + 12 + 16 { wcSendStatus(2); return }
    let ctLen = raw.count - 44 - 16
    if ctLen <= 0 || ctLen > 240 { wcSendStatus(2); return }
    var key = [UInt8](repeating: 0, count: 32)
    let derived = raw.withUnsafeBufferPointer { rp in
      key.withUnsafeMutableBufferPointer { kp in fm_wc_derive_key(rp.baseAddress, kp.baseAddress) }
    }
    if derived == 0 { wcSendStatus(2); return }
    var pt = [UInt8](repeating: 0, count: 256)
    let dec = raw.withUnsafeBufferPointer { rp -> Int32 in
      key.withUnsafeBufferPointer { kp in
        pt.withUnsafeMutableBufferPointer { pp in
          let rb = rp.baseAddress!
          return fm_wc_gcm_decrypt(kp.baseAddress, rb + 32, rb + 44, Int32(ctLen),
                                   rb + 44 + ctLen, pp.baseAddress)
        }
      }
    }
    if dec == 0 { wcSendStatus(2); return }
    // plaintext: <ssidLen> ssid <passLen> pass  (bounded to the 64-byte buffers)
    var ok = false
    if ctLen >= 1 {
      let sl = Int(pt[0])
      if sl > 0 && sl <= 63 && 1 + sl < ctLen {
        for k in 0..<sl { gSsid[k] = pt[1 + k] }; gSsid[sl] = 0
        let pl = Int(pt[1 + sl])
        if pl <= 63 && 2 + sl + pl <= ctLen {
          for k in 0..<pl { gPass[k] = pt[2 + sl + k] }; gPass[pl] = 0
          ok = true
        }
      }
    }
    if ok {
      gSsid.withUnsafeBufferPointer { sp in
        gPass.withUnsafeBufferPointer { pp in fm_nvs_save_creds(sp.baseAddress, pp.baseAddress) }
      }
      _ = applyActiveCreds()
    }
    wcSendStatus(fm_wifi_connected() != 0 ? 1 : 0)
  default: break
  }
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
    liveHandler.process(UInt8(fm_tcp_read() & 0xFF)); g += 1
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
  while b >= 0 && g < 4096 { liveHandler.process(UInt8(b & 0xFF)); g += 1; b = fm_ble_rx_pop() }
}

// ===========================================================================
//  Entry point — ESP-IDF app_main (C) calls sw_main(); Swift owns the run loop.
// ===========================================================================
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
    loopTick()
    fm_delay_ms(1)
  }
}
