// Compile-time user configuration (Wi-Fi credentials, board/BLE names).

/* ==== User configuration ================================================ */
let WIFI_SSID: StaticString = "YOUR_WIFI_SSID"
let WIFI_PASS: StaticString = "YOUR_WIFI_PASSWORD"
let MDNS_HOST: StaticString = "firmata-wifi-esp32"
let BLE_NAME:  StaticString = "firmata-ble-esp32"
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
