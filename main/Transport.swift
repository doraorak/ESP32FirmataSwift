// Transport orchestration in Swift: Wi-Fi/Bonjour (TCP) and BLE (NUS); vendor calls bridged through fm_*.

/* ==== Transport — Wi-Fi / Bonjour (orchestration in Swift; vendor calls bridged) ==== */
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
    let prevSsid = gSsid, prevPass = gPass            // for rollback if the new creds fail
    let wasConnected = fm_wifi_connected() != 0
    var parsed = false
    if ctLen >= 1 {
      let sl = Int(pt[0])
      if sl > 0 && sl <= 63 && 1 + sl < ctLen {
        for k in 0..<sl { gSsid[k] = pt[1 + k] }; gSsid[sl] = 0
        let pl = Int(pt[1 + sl])
        if pl <= 63 && 2 + sl + pl <= ctLen {
          for k in 0..<pl { gPass[k] = pt[2 + sl + k] }; gPass[pl] = 0
          parsed = true
        }
      }
    }
    if !parsed {                                       // malformed -> undo any partial write
      gSsid = prevSsid; gPass = prevPass
      wcSendStatus(fm_wifi_connected() != 0 ? 1 : 0); return
    }
    if applyActiveCreds() {                            // new creds joined -> persist them
      gSsid.withUnsafeBufferPointer { sp in
        gPass.withUnsafeBufferPointer { pp in fm_nvs_save_creds(sp.baseAddress, pp.baseAddress) }
      }
      wcSendStatus(1)
    } else {                                           // failed -> revert, leave NVS untouched
      gSsid = prevSsid; gPass = prevPass
      if wasConnected { _ = applyActiveCreds() }
      wcSendStatus(0)
    }
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

/* ==== Transport — BLE (orchestration in Swift; vendor events bridged via FIFO/flags) ==== */
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

/* Firmata over USB serial (UART0 — the log console port). The first byte a host
   sends claims the session: the console goes quiet (logs would corrupt frames)
   and serial becomes the master until another transport claims it. There is no
   serial "disconnect" event, so the claim persists until eviction or reboot. */
func serialPoll() {
  var g = 0
  while fm_serial_available() != 0 && g < 1024 {
    let b = fm_serial_read()
    if b < 0 { break }
    if activeTransport != TR_SERIAL {
      fm_console_quiet()
      claimMaster(TR_SERIAL)
    }
    liveHandler.process(UInt8(b & 0xFF)); g += 1
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
