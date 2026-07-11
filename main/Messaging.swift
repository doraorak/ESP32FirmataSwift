// Outgoing frame transport (master arbitration), outgoing Firmata messages, and pin/I2C I/O handlers.

/* ==== Outgoing frame transport (routes to the current master) =========== */
func sendFrame(_ buf: [UInt8], _ len: Int) {
  if activeTransport == TR_TCP {
    buf.withUnsafeBufferPointer { fm_tcp_write($0.baseAddress, Int32(len)) }
  } else if activeTransport == TR_BLE {
    bleSend(buf, len)
  } else if activeTransport == TR_SERIAL {
    buf.withUnsafeBufferPointer { fm_serial_write($0.baseAddress, Int32(len)) }
  }
}

/* ==== Outgoing Firmata messages ========================================= */
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
      frameBuf[n] = PIN_MODE_PULLDOWN; n += 1; frameBuf[n] = 1; n += 1
      frameBuf[n] = PIN_MODE_OUTPUT; n += 1; frameBuf[n] = 1; n += 1
      frameBuf[n] = PIN_MODE_PWM;    n += 1; frameBuf[n] = 14; n += 1   // up to 14-bit via PWM_CONFIG
      frameBuf[n] = PIN_MODE_SERVO;  n += 1; frameBuf[n] = 14; n += 1
      if pin == I2C_SDA_PIN || pin == I2C_SCL_PIN { frameBuf[n] = PIN_MODE_I2C; n += 1; frameBuf[n] = 1; n += 1 }
      if analogChannelOfPin(pin) >= 0 { frameBuf[n] = PIN_MODE_ANALOG; n += 1; frameBuf[n] = 12; n += 1 }
      if touchSensorOfPin(pin) >= 0 { frameBuf[n] = PIN_MODE_TOUCH; n += 1; frameBuf[n] = 14; n += 1 }
      if isDACPin(pin) { frameBuf[n] = PIN_MODE_DAC; n += 1; frameBuf[n] = 8; n += 1 }
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

/* ==== Pin I/O handlers
    I2C device helpers (shared by the live handler and periodic sampling)
   ==================== */
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
