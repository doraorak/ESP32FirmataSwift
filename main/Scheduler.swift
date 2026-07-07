// Firmata Scheduler (SysEx 0x7B) + the on-device task extension (registers, branches, arithmetic, HTTP/JSON/string, nested tasks — ext ops 0x10–0x30).

/* ==== Firmata Scheduler (SysEx 0x7B)
    Stores tasks (recorded Firmata bytes + delays) and replays them — through a
    dedicated FirmataProtocol instance (`replay`) — even with no host connected.
    Also owns the non-standard logic extension (16 Int32 registers, if/else and
    internet actions).
   ==================== */
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

  /* Task bodies may themselves contain CREATE/ADD/SCHEDULE/DELETE messages (the
     client recorder's `addTask`/`deleteTask` — a task spawning tasks). They arrive
     here through the replay handler exactly like host messages. The one hazard is a
     task deleting then re-creating its OWN id mid-run: never hand out the instance
     currently being replayed (`running`), whose data/pos `execute()` is iterating. */
  func create(_ id: UInt8, _ len: UInt16) {
    if find(id) != nil || len > UInt16(MAX_TASK_BYTES) { sendError(id); return }
    for i in 0..<MAX_TASKS where !tasks[i].used {
      let t = tasks[i]
      if let r = running, r === t { continue }   // instance being replayed is off-limits
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
    t.loopDepth = 0
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

  /* ---- NON-STANDARD logic extension (NONSTANDARD.md) ----
     An operand carries both an int and a float view; `isFloat` says which one is
     authoritative (so a comparison promotes to float when either side is float). */
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
      let v = (i < payloadLen) ? regs[Int(payload[i] & REG_MASK)] : 0; i += 1
      return Operand(isFloat: false, i: v, f: Float(v))
    case 2:                            // float register
      let r = (i < payloadLen) ? fregs[Int(payload[i] & FREG_MASK)] : 0; i += 1
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

  /* Counted loop (SCHED_EXT_LOOP / _END). LOOP pushes (iterations, gap, body-start pos);
     LOOP_END decrements and either jumps back (gap ms apart, via the delay-suspend) or pops.
     `count == 0` or nesting past MAX_LOOP_DEPTH skips the body outright. */
  func loopBegin(_ count: UInt16, _ gap: UInt32, _ skipLen: UInt16) {
    guard let t = running else { return }
    if count == 0 || t.loopDepth >= MAX_LOOP_DEPTH {
      skip(skipLen)                      // run the body zero times: jump past body + LOOP_END
      return
    }
    t.loopRemaining[t.loopDepth] = count
    t.loopGap[t.loopDepth] = gap
    t.loopResume[t.loopDepth] = t.pos    // pos is just past the LOOP op = start of the body
    t.loopDepth += 1
  }

  func loopEnd() {
    guard let t = running else { return }
    if t.loopDepth == 0 { return }       // malformed stream; ignore
    let d = t.loopDepth - 1
    t.loopRemaining[d] &-= 1
    if t.loopRemaining[d] > 0 {
      t.pos = t.loopResume[d]            // jump back to the body's first op
      if t.loopGap[d] > 0 { delayRunning(t.loopGap[d]) }   // pause between iterations
    } else {
      t.loopDepth -= 1                   // loop finished: pop and fall through
    }
  }

  func handleExt(_ payload: [UInt8], _ payloadLen: Int) {
    switch payload[0] {
    case SCHED_EXT_SET:                 // 0x10 reg <const:5>
      if payloadLen == 7 { regs[Int(payload[1] & REG_MASK)] = Int32(bitPattern: sched7BitTime(Array(payload[2..<7]))) }
    case SCHED_EXT_READ_DIGITAL:        // 0x11 reg pin
      if payloadLen == 3 { regs[Int(payload[1] & REG_MASK)] = (digitalRead(payload[2]) != 0) ? 1 : 0 }
    case SCHED_EXT_READ_ANALOG:         // 0x12 reg channel
      if payloadLen == 3 {
        let pin = pinOfAnalogChannel(Int(payload[2]))
        regs[Int(payload[1] & REG_MASK)] = (pin >= 0) ? Int32(analogRead(UInt8(pin))) : 0
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
    case SCHED_EXT_STR_BODY_LEN:      // 0x28 dst
      strBodyLen(payload, payloadLen)
    case SCHED_EXT_STR_EQUALS:        // 0x29 dst strLo strHi str…
      strEquals(payload, payloadLen)
    case SCHED_EXT_STR_INDEXOF:       // 0x2A dst strLo strHi str…
      strIndexOf(payload, payloadLen)
    case SCHED_EXT_STR_TO_NUM:        // 0x2B dst found
      strToNum(payload, payloadLen)
    case SCHED_EXT_JSON_GET_STRING:   // 0x2C slot pathLo pathHi path…
      jsonGetString(payload, payloadLen)
    case SCHED_EXT_STR_SET_SLOT:      // 0x2D slot strLo strHi str…
      strSetSlot(payload, payloadLen)
    case SCHED_EXT_STR_COPY_SLOT:     // 0x2E dst src
      strCopySlot(payload, payloadLen)
    case SCHED_EXT_I2C_READ:          // 0x2F addr regLo regHi count dst
      i2cReadReg(payload, payloadLen)
    case SCHED_EXT_EMIT_STRING:       // 0x30 lenLo lenHi bytes…
      emitString(payload, payloadLen)
    case SCHED_EXT_REG_QUERY:         // 0x31: snapshot R0-15 + F0-7 to the host
      regReport()
    case SCHED_EXT_WRITE_PIN:         // 0x32 kind pin <operand>
      writePinOp(payload, payloadLen)
    case SCHED_EXT_MODULE_OP:         // 0x33 <moduleId> <payload…>
      if payloadLen >= 2 { moduleDispatch(payload[1], Array(payload[2..<payloadLen]), payloadLen - 2) }
    case SCHED_EXT_LOOP:             // 0x34 countLo countHi gapLo gapHi skipLo skipHi
      if payloadLen == 7 {
        let count   = UInt16(payload[1]) | (UInt16(payload[2]) << 7)
        let gap     = UInt32(payload[3]) | (UInt32(payload[4]) << 7)
        let skipLen = UInt16(payload[5]) | (UInt16(payload[6]) << 7)
        loopBegin(count, gap, skipLen)
      }
    case SCHED_EXT_LOOP_END:         // 0x35
      loopEnd()
    default:
      break
    }
  }

  /* 0x2F: write the register pointer, read <count> (1…4) bytes from the I2C device,
           and store them big-endian in R[dst]. Lets a task act on an I2C sensor with
           nobody connected (the read reply is consumed on-device, not sent to a host). */
  func i2cReadReg(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 6 { return }
    let address = UInt16(payload[1] & 0x7F)
    let reg     = Int(payload[2]) | (Int(payload[3]) << 7)
    var count   = Int(payload[4]); if count < 1 { count = 1 }; if count > 4 { count = 4 }
    let dst     = Int(payload[5] & REG_MASK)
    fm_i2c_begin_transmission(Int32(address))
    fm_i2c_write(Int32(reg))
    _ = fm_i2c_end_transmission(1)
    if i2cReadDelayUs != 0 { fm_delay_us(UInt32(i2cReadDelayUs)) }
    let got = Int(fm_i2c_request_from(Int32(address), Int32(count)))
    var v: Int32 = 0
    var i = 0
    while fm_i2c_available() != 0 && i < got && i < count {
      v = (v << 8) | (Int32(fm_i2c_read()) & 0xFF); i += 1     // big-endian pack
    }
    regs[dst] = v
  }

  /* 0x32: write a pin from an OPERAND (register or literal) — the piece that
     lets task values drive outputs: kind 0 = digital (non-zero -> HIGH, OUTPUT
     pins only), kind 1 = analog, routed by the pin's mode (PWM duty or servo
     degrees/us). Float operands truncate. */
  func writePinOp(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 4 { return }
    let kind = payload[1]
    let pin = Int(payload[2] & 0x7F)
    if pin >= TOTAL_PINS { return }
    var i = 3
    let v = readOperand(payload, payloadLen, &i)
    let value = Int(v.isFloat ? f2i(v.f) : v.i)
    if kind == 0 {
      if pinModes[pin] == PIN_MODE_OUTPUT {
        digitalWrite(UInt8(pin), value != 0 ? 1 : 0)
        pinValues[pin] = value != 0 ? 1 : 0
      }
    } else {
      if pinModes[pin] == PIN_MODE_PWM { pwm(pin, value); pinValues[pin] = value }
      else if pinModes[pin] == PIN_MODE_SERVO { replay.servoOut(pin, value) }
    }
  }

  /* 0x31: report every register to the connected host as SCHED_REG_REPLY —
     16 Int32s then 8 float bit-patterns, each as 5 little-endian 7-bit limbs.
     Works live (host polls shared state) or from inside a task. */
  func regReport() {
    var n = 0
    frameBuf[n] = START_SYSEX; n += 1
    frameBuf[n] = SCHEDULER_DATA; n += 1
    frameBuf[n] = SCHED_REG_REPLY; n += 1
    for i in 0..<NUM_SCHED_REGS {
      var v = UInt32(bitPattern: regs[i])
      for _ in 0..<5 { frameBuf[n] = UInt8(v & 0x7F); n += 1; v >>= 7 }
    }
    for i in 0..<NUM_FLOAT_REGS {
      var v = fregs[i].bitPattern
      for _ in 0..<5 { frameBuf[n] = UInt8(v & 0x7F); n += 1; v >>= 7 }
    }
    frameBuf[n] = END_SYSEX; n += 1
    sendFrame(frameBuf, n)
  }

  // 0x30: send a STRING_DATA frame (board -> host) so a running task can report a
  //       message to a connected master (over TCP or BLE). No-op if nobody is connected.
  func emitString(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 3 { return }
    let sLen = Int(payload[1]) | (Int(payload[2]) << 7)
    if 3 + sLen > payloadLen { return }
    var out = [UInt8](repeating: 0, count: 3 + sLen * 2)
    var n = 0
    out[n] = START_SYSEX; n += 1
    out[n] = STRING_DATA; n += 1
    for k in 0..<sLen {
      out[n] = payload[3 + k] & 0x7F; n += 1                   // LSB (ASCII char)
      out[n] = 0; n += 1                                       // MSB
    }
    out[n] = END_SYSEX; n += 1
    sendFrame(out, n)
  }

  /* ---- Internet action: a task (or a live host) makes an HTTP(S) request over
          the board's Wi-Fi. Layout of the ext payload:
            0x15 method statusReg urlLo urlHi url[urlLen] bodyLo bodyHi body[bodyLen]
          method 0=GET 1=POST. URL/body are raw ASCII (7-bit). On execution
          R[statusReg] = HTTP status (0 = Wi-Fi down / error); the full response
          body is retained for the inspection ops (JSON_NUM / *_STR_* / BODY_*).
          If a host is connected, status + body are also sent as SCHED_EXT_HTTP_REPLY. */
  func http(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 5 { return }
    let method    = payload[1]
    let statusReg = Int(payload[2] & REG_MASK)
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
    regs[Int(payload[1] & REG_MASK)] = requestCount
  }

  /* ====== Response inspection — walks the selected source IN PLACE ======
     Source is the live body (fm_http_resp_ptr) or a snapshot slot, chosen by
     SELECT. Returns (ptr, len, stale) — `stale` is set when a borrowed (live)
     source was selected against an out-of-date generation. Each op records a
     result-status in `lastStatus` (read with SCHED_EXT_LAST_STATUS). */
  func inspectBuf() -> (UnsafePointer<UInt8>?, Int, Bool) {
    if inspectSel == 0 { return (fm_http_resp_ptr(), Int(fm_http_resp_len()), inspectStale) }
    let s = Int32(inspectSel - 1)
    return (fm_snapshot_ptr(s), Int(fm_snapshot_len(s)), false)
  }

  // 0x16: R[dst] = number at JSON <path> × 10^scale (truncated); R[found] = 0/1.
  func jsonNumber(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 6 { return }
    let dst = Int(payload[1] & REG_MASK), foundReg = Int(payload[2] & REG_MASK), scale = Int(payload[3])
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
    let dst = Int(payload[1] & REG_MASK)
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
    let dst = Int(payload[1] & REG_MASK)
    let strLen = Int(payload[2]) | (Int(payload[3]) << 7)
    if 4 + strLen > payloadLen { return }
    let needle = Array(payload[4..<4 + strLen])
    regs[dst] = 0
    let (bOpt, bufLen, stale) = inspectBuf()
    if stale { lastStatus = ST_STALE; return }
    guard bufLen > 0, let buf = bOpt else { lastStatus = ST_NOT_FOUND; return }
    regs[dst] = bytesContain(buf, 0, bufLen, needle) ? 1 : 0; lastStatus = ST_OK
  }

  // 0x28: R[dst] = byte length of the selected body (raw string).
  func strBodyLen(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 2 { return }
    let dst = Int(payload[1] & REG_MASK)
    regs[dst] = 0
    let (bOpt, bufLen, stale) = inspectBuf()
    if stale { lastStatus = ST_STALE; return }
    guard bOpt != nil else { lastStatus = ST_NOT_FOUND; return }
    regs[dst] = Int32(bufLen); lastStatus = ST_OK
  }

  // 0x29: R[dst] = (selected body == <str>) ? 1 : 0.
  func strEquals(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 4 { return }
    let dst = Int(payload[1] & REG_MASK)
    let sLen = Int(payload[2]) | (Int(payload[3]) << 7)
    if 4 + sLen > payloadLen { return }
    regs[dst] = 0
    let (bOpt, bufLen, stale) = inspectBuf()
    if stale { lastStatus = ST_STALE; return }
    guard let buf = bOpt else { lastStatus = ST_NOT_FOUND; return }
    if bufLen == sLen {
      var eq = true
      for k in 0..<sLen where buf[k] != payload[4 + k] { eq = false; break }
      regs[dst] = eq ? 1 : 0
    }
    lastStatus = ST_OK
  }

  // 0x2A: R[dst] = index of <str> in the selected body, or -1.
  func strIndexOf(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 4 { return }
    let dst = Int(payload[1] & REG_MASK)
    let sLen = Int(payload[2]) | (Int(payload[3]) << 7)
    if 4 + sLen > payloadLen { return }
    regs[dst] = -1
    let (bOpt, bufLen, stale) = inspectBuf()
    if stale { lastStatus = ST_STALE; return }
    guard let buf = bOpt else { lastStatus = ST_NOT_FOUND; return }
    let needle = Array(payload[4..<4 + sLen])
    if needle.isEmpty { regs[dst] = 0; lastStatus = ST_OK; return }
    if bufLen >= needle.count {
      var i = 0
      while i <= bufLen - needle.count {
        var m = true
        for t in 0..<needle.count where buf[i + t] != needle[t] { m = false; break }
        if m { regs[dst] = Int32(i); break }
        i += 1
      }
    }
    lastStatus = ST_OK
  }

  // 0x2B: R[dst] = body parsed as a leading integer; R[found] = 0/1.
  func strToNum(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 3 { return }
    let dst = Int(payload[1] & REG_MASK), foundReg = Int(payload[2] & REG_MASK)
    regs[dst] = 0; regs[foundReg] = 0
    let (bOpt, bufLen, stale) = inspectBuf()
    if stale { lastStatus = ST_STALE; return }
    guard let buf = bOpt, bufLen > 0 else { lastStatus = ST_NOT_FOUND; return }
    var i = 0
    while i < bufLen, buf[i] == 0x20 || buf[i] == 0x09 { i += 1 }   // skip leading whitespace
    var negative = false
    if i < bufLen, buf[i] == 0x2D { negative = true; i += 1 }
    else if i < bufLen, buf[i] == 0x2B { i += 1 }
    var val: Int32 = 0; var any = false
    while i < bufLen, buf[i] >= 0x30, buf[i] <= 0x39 {
      any = true
      if val > 214748364 { val = 2147483647 }                       // clamp (wrapping ops, no checked mul)
      else { val = val &* 10 &+ Int32(buf[i] - 0x30) }
      i += 1
    }
    if any {
      regs[dst] = negative ? (0 &- val) : val; regs[foundReg] = 1; lastStatus = ST_OK
    } else { lastStatus = ST_TYPE_MISMATCH }
  }

  // 0x1A: integer arithmetic. R[dst] = A <op> B  (op: 0+ 1- 2* 3/ 4%).
  // 64-bit intermediates avoid overflow traps; ÷ / % by zero yield 0.
  func arith(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 3 { return }
    let sub = payload[1], dst = Int(payload[2] & REG_MASK)
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

  /* 0x27: comparison. R[dst] = (A <op> B) ? 1 : 0  (op: 0== 1!= 2< 3> 4<= 5>=).
     Reuses the same operand decoding + float-promoting compare as SCHED_EXT_IF, so a
     task can materialise a reusable boolean register instead of branching inline. */
  func cmp(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 3 { return }
    let op = payload[1], dst = Int(payload[2] & REG_MASK)
    var i = 3
    let a = readOperand(payload, payloadLen, &i)
    let b = readOperand(payload, payloadLen, &i)
    regs[dst] = compare(op, a, b) ? 1 : 0
  }

  // 0x1C: float arithmetic. F[dst] = A <op> B  (op: 0+ 1- 2* 3/). ÷0 → 0.
  func arithFloat(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 3 { return }
    let sub = payload[1], dst = Int(payload[2] & FREG_MASK)
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
    fregs[Int(payload[1] & FREG_MASK)] = Float(bitPattern: sched7BitTime(Array(payload[2..<7])))
  }

  // 0x1D: F[dst] = json float at <path>; R[found] = 0/1.
  func jsonFloat(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 5 { return }
    let dst = Int(payload[1] & FREG_MASK), foundReg = Int(payload[2] & REG_MASK)
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
    let dst = Int(payload[1] & REG_MASK)
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
  // 0x2C: copy the CONTENT (unquoted) of the JSON string at <path> from the LIVE body into
  //       snapshot slot <slot>. Backs board.json.getString → a TaskString for board.string.
  func jsonGetString(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 4 { return }
    let slot = Int(payload[1]); if slot < 0 || slot >= NUM_SNAP { return }
    let pathLen = Int(payload[2]) | (Int(payload[3]) << 7)
    if 4 + pathLen > payloadLen { return }
    let path = Array(payload[4..<4 + pathLen])
    let bufLen = Int(fm_http_resp_len())
    guard bufLen > 0, let buf = fm_http_resp_ptr() else { lastStatus = ST_NOT_FOUND; return }
    guard let (s, e) = jsonValueSpan(buf, bufLen, path), e > s else { lastStatus = ST_NOT_FOUND; return }
    guard buf[s] == 0x22, e - 1 > s else { lastStatus = ST_TYPE_MISMATCH; return }   // must be a JSON string
    let ok = Int(fm_snapshot_copy(Int32(slot), buf + s + 1, Int32((e - 1) - (s + 1))))
    lastStatus = (ok != 0) ? ST_OK : ST_ALLOC_FAILED
  }
  // 0x2D: set snapshot slot <slot> to the literal string in the payload — backs
  //       board.string.createString (board.string ops then run on the slot).
  func strSetSlot(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 4 { return }
    let slot = Int(payload[1]); if slot < 0 || slot >= NUM_SNAP { return }
    let sLen = Int(payload[2]) | (Int(payload[3]) << 7)
    if 4 + sLen > payloadLen { return }
    let ok = payload.withUnsafeBufferPointer { p in
      Int(fm_snapshot_copy(Int32(slot), p.baseAddress! + 4, Int32(sLen)))
    }
    lastStatus = (ok != 0) ? ST_OK : ST_ALLOC_FAILED
  }
  // 0x2E: copy snapshot slot <src> content into slot <dst> (backs string changeSlot).
  func strCopySlot(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 3 { return }
    let dst = Int(payload[1]); let src = Int(payload[2])
    if dst < 0 || dst >= NUM_SNAP || src < 0 || src >= NUM_SNAP { return }
    let sl = Int(fm_snapshot_len(Int32(src)))
    guard let sp = fm_snapshot_ptr(Int32(src)) else { lastStatus = ST_NOT_FOUND; return }
    let ok = Int(fm_snapshot_copy(Int32(dst), sp, Int32(sl)))
    lastStatus = (ok != 0) ? ST_OK : ST_ALLOC_FAILED
  }
  // 0x24: select the inspection source — 0 = live body (stale if requestCount != R[expGenReg]),
  //       k = snapshot slot k-1 (always valid).
  func select(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 3 { return }
    inspectSel = Int(payload[1])
    if inspectSel == 0 { inspectStale = (requestCount != regs[Int(payload[2] & REG_MASK)]) }
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
    regs[Int(payload[1] & REG_MASK)] = lastStatus
  }
  // 0x21: R[freeReg] = free heap, R[largestReg] = largest free block.
  func heap(_ payload: [UInt8], _ payloadLen: Int) {
    if payloadLen < 3 { return }
    regs[Int(payload[1] & REG_MASK)] = Int32(truncatingIfNeeded: fm_free_heap())
    regs[Int(payload[2] & REG_MASK)] = Int32(truncatingIfNeeded: fm_largest_free_block())
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
      if t.time_ms != start {               // a DELAY_TASK fired (or a loop's inter-iteration gap)
        if t.pos >= t.len { t.pos = 0; t.loopDepth = 0 }   // trailing delay -> loop from start
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
