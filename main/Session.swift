// System reset and the per-iteration periodic work (scheduler + sampling) run each loop tick.

/* ==== Reset ============================================================= */
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
  moduleReset()          // the pin-mode reset above detaches RMT receivers — let modules re-arm
  for pin in 0..<TOTAL_PINS { toneOffMs[pin] = 0 }; toneTimersActive = 0   // the pin reset stopped any tones
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

/* ==== Periodic work (scheduler + sampling), run each loop iteration ===== */
func loopTick() {
  scheduler.tick()
  moduleTick()
  toneTick()                 // auto-stop any timed tones (cheap when none pending)
  if transportConnected() {
    checkDigitalInputs()
    let now = fm_millis()
    if now &- lastSampleMs >= UInt32(samplingInterval) {
      lastSampleMs = now
      sampleAnalogAndI2C()
    }
  }
}
