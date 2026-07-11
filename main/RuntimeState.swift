// Parser/scheduler value types, runtime pin & reporting state, and PWM (LEDC).

/* ==== Parser + scheduler types ========================================== */
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
let MAX_LOOP_DEPTH = 4          // per-task counted-loop nesting (SCHED_EXT_LOOP)

final class SchedTask {
  var used = false
  var id: UInt8 = 0
  var time_ms: UInt32 = 0       // absolute millis() when due; 0 = not scheduled
  var len: UInt16 = 0
  var pos: UInt16 = 0
  var data = [UInt8](repeating: 0, count: MAX_TASK_BYTES)
  // Counted-loop stack (SCHED_EXT_LOOP / _END): iterations left, gap ms, and the byte
  // position to jump back to for each open loop. Persists across delay-suspends.
  var loopDepth = 0
  var loopRemaining = [UInt16](repeating: 0, count: MAX_LOOP_DEPTH)
  var loopGap       = [UInt32](repeating: 0, count: MAX_LOOP_DEPTH)
  var loopResume    = [UInt16](repeating: 0, count: MAX_LOOP_DEPTH)
  /* `once { }` guards already taken this task lifetime (bit = ONCE idx). Cleared on
     (re)schedule only — NOT on the trailing-delay wraparound, so a repeatEvery task
     runs each once-block exactly once until re-uploaded. */
  var onceMask: UInt32 = 0
}

/* ==== Runtime pin / reporting state ===================================== */
var pinModes      = [UInt8](repeating: PIN_MODE_INPUT, count: TOTAL_PINS)
/* Servo pulse range per pin (SERVO_CONFIG overrides the 544-2400 us defaults). */
var servoMinUs    = [Int32](repeating: 544, count: TOTAL_PINS)
var servoMaxUs    = [Int32](repeating: 2400, count: TOTAL_PINS)
/* Max PWM duty per pin: (1 << resolutionBits) - 1. Default 8-bit; PWM_CONFIG overrides. */
var pwmMaxDuty    = [Int](repeating: 255, count: TOTAL_PINS)
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

let NUM_SCHED_REGS = 32   // R0-15 public (user), R16-31 internal (auto-alloc + library scratch)
let NUM_FLOAT_REGS = 16   // F0-7 public, F8-15 internal
let REG_MASK  = UInt8(NUM_SCHED_REGS - 1)   // 0x1F — wire index mask, derived so a resize is one edit
let FREG_MASK = UInt8(NUM_FLOAT_REGS - 1)   // 0x0F

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

// Transport master arbitration (latest-wins): TCP, BLE, or USB serial.
let TR_NONE: UInt8   = 0
let TR_TCP: UInt8    = 1
let TR_BLE: UInt8    = 2
let TR_SERIAL: UInt8 = 3
var activeTransport: UInt8 = TR_NONE

/* ==== PWM -> Arduino analogWrite (LEDC). Duty clamps to the pin's configured
   resolution — 8-bit (0..255) by default, PWM_CONFIG can raise it to 14-bit. ==== */
@inline(__always) func pwm(_ pin: Int, _ value: Int) {
  let hi = pwmMaxDuty[pin]
  let v = value < 0 ? 0 : (value > hi ? hi : value)
  fm_pwm_write(Int32(pin), Int32(v))   // routes PWM_CONFIG pins to their IDF channel
}
