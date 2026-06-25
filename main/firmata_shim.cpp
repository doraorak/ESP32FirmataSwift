//===----------------------------------------------------------------------===//
// firmata_shim.cpp — BRIDGING ONLY.
//
// No implementation logic lives here. Every function is a thin wrapper over a
// vendor (Arduino / ESP-IDF) API so Embedded Swift can reach it. The protocol,
// Scheduler, logic extension, transport orchestration (Wi-Fi/Bonjour/TCP + BLE),
// arbitration and the main loop are all in Main.swift.
//
// Two things are unavoidably C++ and are kept to pure forwarding:
//   * BLE callback classes — Swift can't subclass a C++ class, so these just
//     push bytes into a FIFO / set event flags that Swift polls.
//   * `app_main` — the ESP-IDF entry; it inits Arduino and calls Swift `sw_main`.
//
// String arguments are passed from Swift as `const uint8_t*` (StaticString /
// byte buffers) and cast to `char*` here.
//===----------------------------------------------------------------------===//
#include "Arduino.h"
#include "WiFi.h"
#include "WiFiClientSecure.h"   // HTTPS (TLS via ssl_client / mbedTLS)
#include "HTTPClient.h"
#include "ESPmDNS.h"
#include "Wire.h"

// IDF certificate bundle (CONFIG_MBEDTLS_CERTIFICATE_BUNDLE=y) — browser-like
// root CA set, so HTTPS certs are validated. Same approach works in the Arduino
// sketch (the core embeds the same bundle).
extern const uint8_t fm_crt_bundle_start[] asm("_binary_x509_crt_bundle_start");
extern const uint8_t fm_crt_bundle_end[]   asm("_binary_x509_crt_bundle_end");
#include "BLEDevice.h"
#include "BLEServer.h"
#include "BLEUtils.h"
#include "BLE2902.h"

// ===========================================================================
//  Encrypted Wi-Fi provisioning crypto + NVS (mbedTLS + Preferences).
//  Ephemeral X25519 ECDH -> HKDF-SHA256 -> AES-256-GCM. Mirrors the C++
//  firmware (ESP32Firmata); Swift drives it via fm_wc_* / fm_nvs_* below.
// ===========================================================================
#include <Preferences.h>
#include <esp_random.h>
#include <mbedtls/ecdh.h>
#include <mbedtls/ecp.h>
#include <mbedtls/bignum.h>
#include <mbedtls/gcm.h>
#include <mbedtls/hkdf.h>
#include <mbedtls/md.h>
#include <mbedtls/platform_util.h>

static const char WC_HKDF_SALT[] = "firmata-wifi-prov-v1";   // must match the client
static int wc_rng(void *, unsigned char *out, size_t len) { esp_fill_random(out, len); return 0; }
static mbedtls_ecp_group wcGrp; static mbedtls_mpi wcPriv;
static bool wcGrpInit = false, wcHavePriv = false;

// HKDF-SHA256 (RFC 5869) from HMAC — IDF's mbedTLS config omits mbedtls_hkdf, but
// HMAC is always present. Single-block expand (outLen <= 32 == hashLen).
static int wc_hkdf_sha256(const uint8_t *salt, size_t saltLen,
                          const uint8_t *ikm, size_t ikmLen,
                          const uint8_t *info, size_t infoLen,
                          uint8_t *out, size_t outLen) {
  const mbedtls_md_info_t *md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  if (!md || outLen > 32) return -1;
  uint8_t prk[32], t[32];
  int rc = -1;
  if (mbedtls_md_hmac(md, salt, saltLen, ikm, ikmLen, prk) == 0) {     // extract
    mbedtls_md_context_t ctx; mbedtls_md_init(&ctx);
    if (mbedtls_md_setup(&ctx, md, 1) == 0 &&
        mbedtls_md_hmac_starts(&ctx, prk, 32) == 0 &&
        (infoLen == 0 || mbedtls_md_hmac_update(&ctx, info, infoLen) == 0)) {
      uint8_t one = 0x01;                                              // expand T(1)
      if (mbedtls_md_hmac_update(&ctx, &one, 1) == 0 &&
          mbedtls_md_hmac_finish(&ctx, t) == 0) {
        memcpy(out, t, outLen); rc = 0;
      }
    }
    mbedtls_md_free(&ctx);
  }
  mbedtls_platform_zeroize(prk, sizeof(prk));
  mbedtls_platform_zeroize(t, sizeof(t));
  return rc;
}

extern "C" {

// Start a handshake: fresh ephemeral keypair; output our 32-byte public key.
int fm_wc_begin(uint8_t *outPub32) {
  if (!wcGrpInit) {
    mbedtls_ecp_group_init(&wcGrp);
    if (mbedtls_ecp_group_load(&wcGrp, MBEDTLS_ECP_DP_CURVE25519) != 0) return 0;
    wcGrpInit = true;
  }
  if (wcHavePriv) { mbedtls_mpi_free(&wcPriv); wcHavePriv = false; }
  mbedtls_mpi_init(&wcPriv);
  mbedtls_ecp_point Q; mbedtls_ecp_point_init(&Q);
  int rc = mbedtls_ecdh_gen_public(&wcGrp, &wcPriv, &Q, wc_rng, nullptr);
  if (rc == 0) rc = mbedtls_mpi_write_binary_le(&Q.MBEDTLS_PRIVATE(X), outPub32, 32);
  mbedtls_ecp_point_free(&Q);
  if (rc == 0) { wcHavePriv = true; return 1; }
  mbedtls_mpi_free(&wcPriv); return 0;
}

// Finish: ECDH with the peer pubkey, HKDF-SHA256 -> 32-byte AES key. One-shot.
int fm_wc_derive_key(const uint8_t *peerPub32, uint8_t *outKey32) {
  if (!wcHavePriv) return 0;
  mbedtls_ecp_point Qp; mbedtls_ecp_point_init(&Qp);
  mbedtls_mpi z; mbedtls_mpi_init(&z);
  uint8_t secret[32]; int ok = 0;
  if (mbedtls_mpi_read_binary_le(&Qp.MBEDTLS_PRIVATE(X), peerPub32, 32) == 0 &&
      mbedtls_mpi_lset(&Qp.MBEDTLS_PRIVATE(Z), 1) == 0 &&
      mbedtls_ecdh_compute_shared(&wcGrp, &z, &Qp, &wcPriv, wc_rng, nullptr) == 0 &&
      mbedtls_mpi_write_binary_le(&z, secret, 32) == 0) {
    if (wc_hkdf_sha256((const uint8_t *)WC_HKDF_SALT, sizeof(WC_HKDF_SALT) - 1,
                       secret, 32, nullptr, 0, outKey32, 32) == 0) ok = 1;
  }
  mbedtls_platform_zeroize(secret, sizeof(secret));
  mbedtls_mpi_free(&z); mbedtls_ecp_point_free(&Qp);
  mbedtls_mpi_free(&wcPriv); wcHavePriv = false;
  return ok;
}

int fm_wc_gcm_decrypt(const uint8_t *key32, const uint8_t *nonce12,
                      const uint8_t *ct, int ctLen, const uint8_t *tag16, uint8_t *outPt) {
  mbedtls_gcm_context g; mbedtls_gcm_init(&g);
  int ok = (mbedtls_gcm_setkey(&g, MBEDTLS_CIPHER_ID_AES, key32, 256) == 0 &&
            mbedtls_gcm_auth_decrypt(&g, (size_t)ctLen, nonce12, 12, nullptr, 0,
                                     tag16, 16, ct, outPt) == 0) ? 1 : 0;
  mbedtls_gcm_free(&g);
  return ok;
}

// NVS-stored creds (Preferences namespace "wifiprov"). Returns 1 if creds exist.
int fm_nvs_load_creds(uint8_t *ssid, int ssidCap, uint8_t *pass, int passCap) {
  Preferences p; p.begin("wifiprov", true);
  String s = p.getString("ssid", ""); String w = p.getString("pass", "");
  p.end();
  if (s.length() == 0) return 0;
  strncpy((char *)ssid, s.c_str(), ssidCap - 1); ssid[ssidCap - 1] = 0;
  strncpy((char *)pass, w.c_str(), passCap - 1); pass[passCap - 1] = 0;
  return 1;
}
void fm_nvs_save_creds(const uint8_t *ssid, const uint8_t *pass) {
  Preferences p; p.begin("wifiprov", false);
  p.putString("ssid", (const char *)ssid);
  p.putString("pass", (const char *)pass);
  p.end();
}
void fm_nvs_clear_creds(void) { Preferences p; p.begin("wifiprov", false); p.clear(); p.end(); }

} // extern "C"

extern "C" void sw_main(void);   // Swift owns all logic + the run loop

// ===========================================================================
//  Time / GPIO / ADC / Serial  (Arduino HAL passthroughs)
// ===========================================================================
extern "C" {
void         fm_serial_begin(unsigned baud) { Serial.begin(baud); }
void         fm_log(const uint8_t *s)       { Serial.println((const char *)s); }
void         fm_analog_setup(void) {
  analogReadResolution(12);
#if defined(ADC_11db)
  analogSetAttenuation(ADC_11db);
#endif
}
void         fm_pin_mode(int pin, int mode) {   // 0=INPUT 1=OUTPUT 2=INPUT_PULLUP
  pinMode((uint8_t)pin, mode == 1 ? OUTPUT : (mode == 2 ? INPUT_PULLUP : INPUT));
}
unsigned     fm_millis(void)             { return (unsigned)millis(); }
void         fm_delay_ms(unsigned m)     { delay(m); }
void         fm_delay_us(unsigned u)     { delayMicroseconds(u); }

// I2C (Wire)
void fm_i2c_begin(int sda, int scl)       { Wire.begin((uint8_t)sda, (uint8_t)scl); }
void fm_i2c_begin_transmission(int addr)  { Wire.beginTransmission((uint8_t)addr); }
void fm_i2c_write(int b)                  { Wire.write((uint8_t)b); }
int  fm_i2c_end_transmission(int stop)    { return Wire.endTransmission((bool)stop); }
int  fm_i2c_request_from(int addr, int n) { return Wire.requestFrom(addr, n); }
int  fm_i2c_available(void)               { return Wire.available(); }
int  fm_i2c_read(void)                    { return Wire.read(); }

// ===========================================================================
//  Wi-Fi / mDNS  (each call is one vendor API; Swift sequences them)
// ===========================================================================
void fm_wifi_begin(const uint8_t *ssid, const uint8_t *pass, const uint8_t *host) {
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.setAutoReconnect(true);
  WiFi.setHostname((const char *)host);
  WiFi.begin((const char *)ssid, (const char *)pass);
}
int  fm_wifi_connected(void) { return WiFi.status() == WL_CONNECTED ? 1 : 0; }
// 1 if already joined to exactly this ssid+pass (so a re-provision needn't tear it down).
int  fm_wifi_same_network(const uint8_t *ssid, const uint8_t *pass) {
  if (WiFi.status() != WL_CONNECTED) return 0;
  return (WiFi.SSID() == String((const char *)ssid) && WiFi.psk() == String((const char *)pass)) ? 1 : 0;
}
int  fm_wifi_localip(uint8_t *out, int n) {
  String s = WiFi.localIP().toString();
  strncpy((char *)out, s.c_str(), n - 1); out[n - 1] = 0;
  return (int)strlen((char *)out);
}
int  fm_mdns_begin(const uint8_t *host) { MDNS.end(); return MDNS.begin((const char *)host) ? 1 : 0; }
void fm_mdns_add_service(const uint8_t *svc, const uint8_t *proto, int port) {
  MDNS.addService((const char *)svc, (const char *)proto, port);
}
void fm_mdns_add_txt(const uint8_t *svc, const uint8_t *proto, const uint8_t *k, const uint8_t *v) {
  MDNS.addServiceTxt((const char *)svc, (const char *)proto, (const char *)k, (const char *)v);
}

// ===========================================================================
//  HTTP client  (Arduino HTTPClient over Wi-Fi; Swift sequences the call and
//  decides what to do with the result). Response body is held here until the
//  next request; Swift copies it out via fm_http_resp_len / fm_http_resp_copy.
// ===========================================================================
} // extern "C"
static String httpBody;
extern "C" {
// method: 0=GET, 1=POST. url/body/content_type are null-terminated.
// Returns the HTTP status code, or <=0 on error (0 = Wi-Fi down / bad URL).
int fm_http_request(const uint8_t *url, int is_post,
                    const uint8_t *body, const uint8_t *content_type) {
  httpBody = "";
  if (WiFi.status() != WL_CONNECTED) return 0;
  bool https = (strncmp((const char *)url, "https", 5) == 0);
  HTTPClient http;
  http.setConnectTimeout(8000);
  http.setTimeout(8000);
  http.setReuse(false);
  http.setFollowRedirects(HTTPC_FORCE_FOLLOW_REDIRECTS);
  WiFiClientSecure tls;
  WiFiClient plain;
  bool ok;
  if (https) {
    tls.setCACertBundle(fm_crt_bundle_start,
                        (size_t)(fm_crt_bundle_end - fm_crt_bundle_start));  // validate certs
    ok = http.begin(tls, (const char *)url);
  } else {
    ok = http.begin(plain, (const char *)url);
  }
  if (!ok) return 0;
  int code;
  if (is_post) {
    if (content_type && content_type[0]) http.addHeader("Content-Type", (const char *)content_type);
    code = http.POST((uint8_t *)body, body ? strlen((const char *)body) : 0);
  } else {
    code = http.GET();
  }
  if (code > 0) httpBody = http.getString();
  http.end();
  return code;
}
int fm_http_resp_len(void) { return (int)httpBody.length(); }
// Borrow the retained body in place (Swift walks it directly — no copy).
const uint8_t *fm_http_resp_ptr(void) { return (const uint8_t *)httpBody.c_str(); }
// Heap stats so a task can size-gate before allocating.
int fm_free_heap(void)         { return (int)ESP.getFreeHeap(); }
int fm_largest_free_block(void) {
  return (int)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT | MALLOC_CAP_INTERNAL);
}

// ---- JSON snapshot slots: owned copies of a response (sub)value that survive
//      the next request. Grow-only buffers (realloc only when bigger) to avoid
//      heap-fragmenting churn. Stable pointers so Swift can walk them in place.
#define FM_NUM_SNAP 2
static uint8_t *fm_snap[FM_NUM_SNAP]   = {nullptr, nullptr};
static int      fm_snapCap[FM_NUM_SNAP] = {0, 0};
static int      fm_snapLen[FM_NUM_SNAP] = {0, 0};
// Returns 1 on success, 0 on alloc failure.
int fm_snapshot_copy(int slot, const uint8_t *src, int len) {
  if (slot < 0 || slot >= FM_NUM_SNAP || len < 0) return 0;
  if (len > fm_snapCap[slot]) {                 // grow-only: never shrink the buffer
    uint8_t *nb = (uint8_t *)realloc(fm_snap[slot], (size_t)len);
    if (!nb) { return 0; }
    fm_snap[slot] = nb; fm_snapCap[slot] = len;
  }
  if (len > 0) memcpy(fm_snap[slot], src, (size_t)len);
  fm_snapLen[slot] = len;
  return 1;
}
const uint8_t *fm_snapshot_ptr(int slot) { return (slot >= 0 && slot < FM_NUM_SNAP) ? fm_snap[slot] : nullptr; }
int fm_snapshot_len(int slot)            { return (slot >= 0 && slot < FM_NUM_SNAP) ? fm_snapLen[slot] : 0; }
void fm_snapshot_free(int slot) {
  if (slot < 0 || slot >= FM_NUM_SNAP) return;
  free(fm_snap[slot]); fm_snap[slot] = nullptr; fm_snapCap[slot] = 0; fm_snapLen[slot] = 0;
}
int fm_http_resp_copy(uint8_t *dst, int max) {
  int n = (int)httpBody.length();
  if (n > max) n = max;
  memcpy(dst, httpBody.c_str(), (size_t)n);
  return n;
}
} // extern "C"

// ===========================================================================
//  TCP server / client  (one vendor op each; Swift drives accept/read/write)
// ===========================================================================
static WiFiServer *tcpServer = nullptr;
static WiFiClient  tcpClient;
static WiFiClient  tcpIncoming;
extern "C" {
void fm_tcp_begin(int port)   { if (!tcpServer) tcpServer = new WiFiServer((uint16_t)port);
                                tcpServer->begin(); tcpServer->setNoDelay(true); }
int  fm_tcp_poll_new(void)    { if (!tcpServer) return 0; WiFiClient c = tcpServer->available();
                                if (c) { tcpIncoming = c; return 1; } return 0; }
void fm_tcp_promote(void)     { tcpClient = tcpIncoming; tcpClient.setNoDelay(true); }
int  fm_tcp_connected(void)   { return (tcpClient && tcpClient.connected()) ? 1 : 0; }
int  fm_tcp_available(void)   { return (tcpClient && tcpClient.connected()) ? tcpClient.available() : 0; }
int  fm_tcp_read(void)        { return tcpClient.read(); }
void fm_tcp_write(const uint8_t *b, int n) { if (tcpClient && tcpClient.connected()) tcpClient.write(b, (size_t)n); }
void fm_tcp_drop(void)        { if (tcpClient && tcpClient.connected()) tcpClient.stop(); }
} // extern "C"

// ===========================================================================
//  BLE Nordic UART Service.
//  Callbacks are pure forwarders into a FIFO / event flags that Swift polls —
//  no protocol/transport logic here. (Swift can't subclass these C++ classes.)
// ===========================================================================
#define NUS_SERVICE_UUID "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define NUS_RX_UUID      "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define NUS_TX_UUID      "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

static BLEServer         *bleServer = nullptr;
static BLECharacteristic *txChar    = nullptr;
static volatile bool      bleConnected = false;
static volatile uint16_t  bleConnId   = 0;
static volatile bool      connectEvt = false, disconnectEvt = false;
static volatile uint16_t  negMTU = 23;

static const int RXSZ = 2048;
static volatile uint8_t   rxb[RXSZ];
static volatile int       rxh = 0, rxt = 0;
static portMUX_TYPE       rxMux = portMUX_INITIALIZER_UNLOCKED;

class RxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *c) override {        // forward bytes to FIFO
    uint8_t *d = c->getData(); size_t n = c->getLength();
    if (!d || !n) return;
    portENTER_CRITICAL(&rxMux);
    for (size_t i = 0; i < n; i++) { int nh = (rxh + 1) % RXSZ; if (nh != rxt) { rxb[rxh] = d[i]; rxh = nh; } }
    portEXIT_CRITICAL(&rxMux);
  }
};
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *s, esp_ble_gatts_cb_param_t *p) override {
    uint16_t nc = p->connect.conn_id;
    if (bleConnected && bleConnId != nc) s->disconnect(bleConnId);   // vendor conn mgmt (newest only)
    bleConnId = nc; bleConnected = true; connectEvt = true;
    s->startAdvertising();
  }
  void onDisconnect(BLEServer *s, esp_ble_gatts_cb_param_t *p) override {
    if (p->disconnect.conn_id == bleConnId) { bleConnected = false; negMTU = 23; disconnectEvt = true; }
    s->startAdvertising();
  }
  void onMtuChanged(BLEServer *, esp_ble_gatts_cb_param_t *p) override { negMTU = p->mtu.mtu; }
};

extern "C" {
void fm_ble_begin(const uint8_t *name) {
  BLEDevice::init((const char *)name);
  BLEDevice::setMTU(517);
  bleServer = BLEDevice::createServer();
  bleServer->setCallbacks(new ServerCallbacks());
  BLEService *svc = bleServer->createService(NUS_SERVICE_UUID);
  BLECharacteristic *rxChar = svc->createCharacteristic(
      NUS_RX_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  rxChar->setCallbacks(new RxCallbacks());
  txChar = svc->createCharacteristic(NUS_TX_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  txChar->addDescriptor(new BLE2902());
  svc->start();
  BLEAdvertising *adv = BLEDevice::getAdvertising();
  BLEAdvertisementData advData;  advData.setFlags(0x06);  advData.setCompleteServices(BLEUUID(NUS_SERVICE_UUID));
  BLEAdvertisementData scanResp; scanResp.setName((const char *)name);
  adv->setAdvertisementData(advData); adv->setScanResponseData(scanResp);
  adv->setMinPreferred(0x06); adv->setMinPreferred(0x12);
  BLEDevice::startAdvertising();
}
int  fm_ble_connected(void)      { return bleConnected ? 1 : 0; }
int  fm_ble_mtu(void)            { return (int)negMTU; }
void fm_ble_notify(const uint8_t *b, int n) {                 // one notification (Swift chunks)
  if (!bleConnected || !txChar) return;
  txChar->setValue((uint8_t *)b, (size_t)n); txChar->notify();
}
void fm_ble_drop(void)           { if (bleConnected && bleServer) bleServer->disconnect(bleConnId); }
int  fm_ble_poll_connect(void)   { if (connectEvt)    { connectEvt = false;    return 1; } return 0; }
int  fm_ble_poll_disconnect(void){ if (disconnectEvt) { disconnectEvt = false; return 1; } return 0; }
int  fm_ble_rx_pop(void) {
  int r = -1;
  portENTER_CRITICAL(&rxMux);
  if (rxt != rxh) { r = rxb[rxt]; rxt = (rxt + 1) % RXSZ; }
  portEXIT_CRITICAL(&rxMux);
  return r;
}

// ===========================================================================
//  ESP-IDF entry — init Arduino, hand everything to Swift.
// ===========================================================================
void app_main(void) { initArduino(); sw_main(); }
} // extern "C"
