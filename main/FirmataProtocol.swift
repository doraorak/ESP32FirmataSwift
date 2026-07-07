// Firmware identity, Firmata protocol constants, and the ESP32 pin model.

/* ==== Firmware identity (firmware-report message) ======================= */
let FIRMWARE_NAME: StaticString = "swiftFirmataESP32"
let FIRMWARE_MAJOR: UInt8 = 2
let FIRMWARE_MINOR: UInt8 = 15
let PROTOCOL_MAJOR: UInt8 = 2
let PROTOCOL_MINOR: UInt8 = 8

/* ==== Firmata protocol constants ======================================== */
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
let SERVO_CONFIG: UInt8            = 0x70
let SAMPLING_INTERVAL: UInt8       = 0x7A
let SCHEDULER_DATA: UInt8          = 0x7B

// Encrypted Wi-Fi provisioning (non-standard; top-level user-range SysEx 0x0C).
let MODULE_DATA: UInt8 = 0x0D      // module subsystem (user-range SysEx)
let MODULE_QUERY: UInt8 = 0x00
let MODULE_LIST_REPLY: UInt8 = 0x7F
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
let SCHED_REG_REPLY: UInt8       = 0x0C   // device -> host: R0-15 + F0-7 snapshot

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
// Raw-string ops over the selected body (board.string). `contains` reuses BODY_CONTAINS (0x18).
let SCHED_EXT_STR_BODY_LEN: UInt8 = 0x28  // R[dst] = byte length of the selected body
let SCHED_EXT_STR_EQUALS: UInt8   = 0x29  // R[dst] = (selected body == <str>) ? 1 : 0
let SCHED_EXT_STR_INDEXOF: UInt8  = 0x2A  // R[dst] = index of <str> in body, or -1
let SCHED_EXT_STR_TO_NUM: UInt8   = 0x2B  // R[dst] = body parsed as int; R[found] = 0/1
let SCHED_EXT_JSON_GET_STRING: UInt8 = 0x2C  // copy a JSON string's content at path into a snapshot slot
let SCHED_EXT_STR_SET_SLOT: UInt8 = 0x2D  // set a snapshot slot's content to a literal string
let SCHED_EXT_STR_COPY_SLOT: UInt8 = 0x2E  // copy one snapshot slot's content into another
let SCHED_EXT_I2C_READ: UInt8     = 0x2F  // R[dst] = <count> bytes read from I2C addr/reg, big-endian
let SCHED_EXT_EMIT_STRING: UInt8  = 0x30  // device -> host: send a STRING_DATA frame to the master
let SCHED_EXT_REG_QUERY: UInt8    = 0x31  // report all registers to the host (SCHED_REG_REPLY)
let SCHED_EXT_WRITE_PIN: UInt8    = 0x32  // write a pin from an operand: kind(0=digital,1=analog) pin <operand>
let SCHED_EXT_MODULE_OP: UInt8    = 0x33  // deliver a payload to a module from a task
let SCHED_EXT_LOOP: UInt8         = 0x34  // begin a counted loop: countLo countHi gapLo gapHi skipLo skipHi
let SCHED_EXT_LOOP_END: UInt8     = 0x35  // end of a counted loop: decrement, jump back + gap, or exit

// Result-status codes (read with SCHED_EXT_LAST_STATUS).
let ST_OK: Int32            = 0
let ST_NOT_FOUND: Int32     = 1
let ST_STALE: Int32         = 2
let ST_TYPE_MISMATCH: Int32 = 3
let ST_TOO_BIG: Int32       = 4
let ST_ALLOC_FAILED: Int32  = 5
let NUM_SNAP = 12   // 2 JSON snapshot slots (0–1) + 10 string slots (2–11)

// Pin modes
let PIN_MODE_INPUT: UInt8  = 0x00
let PIN_MODE_OUTPUT: UInt8 = 0x01
let PIN_MODE_ANALOG: UInt8 = 0x02
let PIN_MODE_PWM: UInt8    = 0x03
let PIN_MODE_SERVO: UInt8  = 0x04
let PIN_MODE_I2C: UInt8    = 0x06
let PIN_MODE_PULLUP: UInt8 = 0x0B

/* ==== ESP32 pin model =================================================== */
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
