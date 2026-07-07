// The live (non-task) Firmata SysEx dispatch — handles each host command as it arrives.

/* ==== Live protocol handler
    Parses an incoming Firmata byte stream (its own ParserState) and applies
    each command. One instance drives the live transport; a second instance
    drives scheduler task replay. Both act on shared device state and route
    scheduler SysEx to the shared `Scheduler`.
   ==================== */
final class FirmataProtocol {
  var ps = ParserState()
  var sched: Scheduler!            // wired once at startup (see sw_main)

  /* Servo value semantics (standard Firmata): < 544 is an angle in degrees
     (0-180 mapped onto the pin's pulse range); >= 544 is a raw pulse width in us. */
  func servoOut(_ pin: Int, _ value: Int) {
    var us: Int32
    if value < 544 {
      let a = Int32(value < 0 ? 0 : (value > 180 ? 180 : value))
      us = servoMinUs[pin] + (servoMaxUs[pin] - servoMinUs[pin]) * a / 180
    } else {
      us = Int32(value)
      if us < servoMinUs[pin] { us = servoMinUs[pin] }
      if us > servoMaxUs[pin] { us = servoMaxUs[pin] }
    }
    fm_servo_write_us(Int32(pin), us)
    pinValues[pin] = Int(us)
  }

  func handleSetPinMode(_ pin: Int, _ mode: UInt8) {
    if pin >= TOTAL_PINS { return }
    if pinModes[pin] == PIN_MODE_SERVO && mode != PIN_MODE_SERVO { fm_servo_detach(Int32(pin)) }
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
    case PIN_MODE_SERVO:
      if isFullDigital(pin) {
        fm_servo_attach(Int32(pin))
        pinModes[pin] = mode; pinValues[pin] = 0; pinConfigured[pin] = true
      }
    case PIN_MODE_I2C:
      pinModes[pin] = mode
    default:
      break
    }
  }

  /* SERVO_CONFIG (0x70): pin, minPulse (14-bit LE), maxPulse (14-bit LE). Sets the
     pulse range and puts the pin in servo mode (standard Firmata behaviour). */
  func handleServoConfig(_ data: [UInt8], _ len: Int) {
    if len < 5 { return }
    let pin = Int(data[0])
    if pin >= TOTAL_PINS || !isFullDigital(pin) { return }
    let minUs = Int32(data[1] & 0x7F) | (Int32(data[2] & 0x7F) << 7)
    let maxUs = Int32(data[3] & 0x7F) | (Int32(data[4] & 0x7F) << 7)
    if minUs > 0 && maxUs > minUs { servoMinUs[pin] = minUs; servoMaxUs[pin] = maxUs }
    handleSetPinMode(pin, PIN_MODE_SERVO)
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
    else if pinModes[pin] == PIN_MODE_SERVO { servoOut(pin, value) }
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
    else if pinModes[pin] == PIN_MODE_SERVO { servoOut(pin, value) }
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
    case SERVO_CONFIG:         handleServoConfig(data, dlen)
    case I2C_CONFIG:           handleI2CConfig(data, dlen)
    case I2C_REQUEST:          handleI2CRequest(data, dlen)
    case SCHEDULER_DATA:       sched.handleSysex(data, dlen)
    case MODULE_DATA:          handleModuleData(data, dlen)
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
