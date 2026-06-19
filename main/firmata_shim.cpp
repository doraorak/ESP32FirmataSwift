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
#include "ESPmDNS.h"
#include "Wire.h"
#include "BLEDevice.h"
#include "BLEServer.h"
#include "BLEUtils.h"
#include "BLE2902.h"

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
//  TCP server / client  (one vendor op each; Swift drives accept/read/write)
// ===========================================================================
} // extern "C"
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
