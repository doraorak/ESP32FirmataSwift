//===----------------------------------------------------------------------===//
// firmata_shim.cpp — C/C++ interop layer for the Embedded-Swift Firmata port.
//
// The Firmata protocol, Scheduler and the register/if-else logic live in
// Main.swift. This file is only the parts that can't be Embedded Swift: the
// Arduino peripheral APIs (pinMode / Wire / Serial / LEDC via analogWrite) and
// BOTH transports from the original ESP32Firmata.ino — Wi-Fi/TCP + Bonjour AND
// BLE (Nordic UART Service) — with the same latest-wins arbitration. It calls
// into Swift for every protocol decision (the sw_* entry points).
//
// digitalWrite / digitalRead / analogRead / analogWrite are Arduino's own
// extern "C" HAL functions; Swift calls them directly (declared in
// BridgingHeader.h) — no wrappers here.
//===----------------------------------------------------------------------===//
#include "Arduino.h"
#include "WiFi.h"
#include "ESPmDNS.h"
#include "Wire.h"
#include "BLEDevice.h"
#include "BLEServer.h"
#include "BLEUtils.h"
#include "BLE2902.h"

// --- USER CONFIGURATION (from ESP32Firmata.ino) ----------------------------
#define WIFI_SSID        "YOUR_WIFI_SSID"
#define WIFI_PASS        "YOUR_WIFI_PASSWORD"
#define MDNS_HOSTNAME    "esp32-firmata"
#define FIRMATA_TCP_PORT 3030
#define BLE_DEVICE_NAME  "Firmata-ESP32"

// ===========================================================================
//  Swift entry points (implemented in Main.swift, @_cdecl)
// ===========================================================================
extern "C" {
  void sw_system_reset(void);
  void sw_claim_master_tcp(void);
  void sw_claim_master_ble(void);
  void sw_tcp_disconnected(void);
  void sw_ble_disconnected(void);
  void sw_process_live_byte(uint8_t b);
  void sw_loop_tick(void);
}

// ===========================================================================
//  Peripheral shims called from Swift (declared in BridgingHeader.h)
// ===========================================================================
extern "C" {

void fm_analog_setup(void) {
  analogReadResolution(12);
#if defined(ADC_11db)
  analogSetAttenuation(ADC_11db);
#endif
}

// pin mode helper (Arduino INPUT/OUTPUT/INPUT_PULLUP macros differ from Firmata's)
void fm_pin_mode(int pin, int mode) {   // 0=INPUT 1=OUTPUT 2=INPUT_PULLUP
  switch (mode) {
    case 1: pinMode((uint8_t)pin, OUTPUT);       break;
    case 2: pinMode((uint8_t)pin, INPUT_PULLUP); break;
    default: pinMode((uint8_t)pin, INPUT);       break;
  }
}

unsigned int fm_millis(void)             { return (unsigned int)millis(); }
void         fm_delay_ms(unsigned int m) { delay(m); }
void         fm_delay_us(unsigned int u) { delayMicroseconds(u); }

// --- I2C (Wire) ---
void fm_i2c_begin(int sda, int scl)       { Wire.begin((uint8_t)sda, (uint8_t)scl); }
void fm_i2c_begin_transmission(int addr)  { Wire.beginTransmission((uint8_t)addr); }
void fm_i2c_write(int b)                  { Wire.write((uint8_t)b); }
int  fm_i2c_end_transmission(int stop)    { return Wire.endTransmission((bool)stop); }
int  fm_i2c_request_from(int addr, int n) { return Wire.requestFrom(addr, n); }
int  fm_i2c_available(void)               { return Wire.available(); }
int  fm_i2c_read(void)                    { return Wire.read(); }

// --- Serial logging ---
void fm_log(const char *s) { Serial.println(s); }
void fm_log_host(const uint8_t *bytes, int n) {
  String s;
  for (int i = 0; i + 1 < n; i += 2) {
    uint16_t cp = (bytes[i] & 0x7F) | ((bytes[i + 1] & 0x7F) << 7);
    if (cp < 128) s += (char)cp;
  }
  Serial.print("[host] "); Serial.println(s);
}

} // extern "C"

// ===========================================================================
//                     TRANSPORT — Wi-Fi / Bonjour (faithful to the .ino)
// ===========================================================================
static WiFiServer tcpServer(FIRMATA_TCP_PORT);
static WiFiClient tcpClient;
static bool       wifiReady = false;

static int buildEvictionFrame(uint8_t *out) {   // STRING_DATA 0x01 "EVICTED"
  static const char *s = "\x01" "EVICTED";
  int n = 0;
  out[n++] = 0xF0; out[n++] = 0x71;
  for (const char *p = s; *p; ++p) { out[n++] = (uint8_t)(*p) & 0x7F; out[n++] = ((uint8_t)(*p) >> 7) & 0x7F; }
  out[n++] = 0xF7;
  return n;
}

extern "C" void fm_tcp_send(const uint8_t *buf, int len) {
  if (tcpClient && tcpClient.connected()) tcpClient.write(buf, (size_t)len);
}
extern "C" void fm_tcp_drop(void) {
  if (tcpClient && tcpClient.connected()) { tcpClient.stop(); Serial.println("Evicted TCP client (latest-wins)"); }
}

static void startBonjour() {
  MDNS.end();
  if (!MDNS.begin(MDNS_HOSTNAME)) { Serial.println("mDNS start failed"); return; }
  MDNS.addService("firmata", "tcp", FIRMATA_TCP_PORT);
  String ip = WiFi.localIP().toString();
  MDNS.addServiceTxt("firmata", "tcp", "ip",   ip.c_str());
  MDNS.addServiceTxt("firmata", "tcp", "port", String(FIRMATA_TCP_PORT).c_str());
  Serial.printf("Bonjour: _firmata._tcp on %s:%d (instance \"%s\")\n", ip.c_str(), FIRMATA_TCP_PORT, MDNS_HOSTNAME);
}
static void startTcpServices() {
  startBonjour();
  tcpServer.begin();
  tcpServer.setNoDelay(true);
  wifiReady = true;
  Serial.print("Wi-Fi up. IP = "); Serial.println(WiFi.localIP());
}
static void tcpInit() {
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.setAutoReconnect(true);
  WiFi.setHostname(MDNS_HOSTNAME);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  Serial.printf("Connecting to Wi-Fi \"%s\"", WIFI_SSID);
  uint8_t tries = 0;
  while (WiFi.status() != WL_CONNECTED && tries < 40) { delay(400); Serial.print('.'); tries++; }
  Serial.println();
  if (WiFi.status() == WL_CONNECTED) startTcpServices();
  else Serial.println("Wi-Fi not up yet (BLE still available, will retry).");
}
static void tcpPoll() {
  if (WiFi.status() != WL_CONNECTED) { if (wifiReady) { wifiReady = false; Serial.println("Wi-Fi lost"); } return; }
  if (!wifiReady) startTcpServices();
  WiFiClient incoming = tcpServer.available();
  if (incoming) {
    if (tcpClient && tcpClient.connected()) { uint8_t nb[24]; tcpClient.write(nb, buildEvictionFrame(nb)); tcpClient.stop(); }
    tcpClient = incoming; tcpClient.setNoDelay(true);
    Serial.println("TCP client connected");
    sw_claim_master_tcp();
  }
  if (!tcpClient || !tcpClient.connected()) sw_tcp_disconnected();
  for (int g = 0; tcpClient && tcpClient.available() && g < 1024; g++) sw_process_live_byte((uint8_t)tcpClient.read());
}

// ===========================================================================
//                     TRANSPORT — BLE (Nordic UART Service, faithful to .ino)
// ===========================================================================
#define NUS_SERVICE_UUID "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define NUS_RX_UUID      "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"  // host -> device
#define NUS_TX_UUID      "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"  // device -> host

static BLEServer         *bleServer = nullptr;
static BLECharacteristic *txChar    = nullptr;
static volatile bool      bleConnected = false;
static volatile uint16_t  bleConnId   = 0;
static volatile bool      bleNewConnect = false;
static bool               bleWasConnected = false;
static volatile uint16_t  negotiatedMTU = 23;

static const int RXBUF_SIZE = 2048;
static volatile uint8_t  rxbuf[RXBUF_SIZE];
static volatile int      rxHead = 0, rxTail = 0;
static portMUX_TYPE      rxMux = portMUX_INITIALIZER_UNLOCKED;

static void rxEnqueue(const uint8_t *d, size_t n) {
  portENTER_CRITICAL(&rxMux);
  for (size_t i = 0; i < n; i++) { int nh = (rxHead + 1) % RXBUF_SIZE; if (nh != rxTail) { rxbuf[rxHead] = d[i]; rxHead = nh; } }
  portEXIT_CRITICAL(&rxMux);
}
static int rxDequeue() {
  int r = -1;
  portENTER_CRITICAL(&rxMux);
  if (rxTail != rxHead) { r = rxbuf[rxTail]; rxTail = (rxTail + 1) % RXBUF_SIZE; }
  portEXIT_CRITICAL(&rxMux);
  return r;
}

class RxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *c) override {
    uint8_t *d = c->getData(); size_t n = c->getLength();
    if (d && n) rxEnqueue(d, n);
  }
};
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *s, esp_ble_gatts_cb_param_t *param) override {
    uint16_t newConn = param->connect.conn_id;
    if (bleConnected && bleConnId != newConn) s->disconnect(bleConnId);   // latest-wins
    bleConnId = newConn; bleConnected = true; bleNewConnect = true;
    s->startAdvertising();
  }
  void onDisconnect(BLEServer *s, esp_ble_gatts_cb_param_t *param) override {
    if (param->disconnect.conn_id == bleConnId) { bleConnected = false; negotiatedMTU = 23; }
    s->startAdvertising();
  }
  void onMtuChanged(BLEServer *, esp_ble_gatts_cb_param_t *param) override { negotiatedMTU = param->mtu.mtu; }
};

static void bleInit() {
  BLEDevice::init(BLE_DEVICE_NAME);
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
  BLEAdvertisementData scanResp; scanResp.setName(BLE_DEVICE_NAME);
  adv->setAdvertisementData(advData); adv->setScanResponseData(scanResp);
  adv->setMinPreferred(0x06); adv->setMinPreferred(0x12);
  BLEDevice::startAdvertising();
  Serial.printf("BLE advertising as \"%s\" (Nordic UART Service)\n", BLE_DEVICE_NAME);
}

extern "C" void fm_ble_drop(void) {
  if (bleConnected && bleServer) { bleServer->disconnect(bleConnId); Serial.println("Evicted BLE central (latest-wins)"); }
}
extern "C" void fm_ble_send(const uint8_t *buf, int len) {
  if (!bleConnected || !txChar) return;
  size_t chunk = (negotiatedMTU > 23) ? (size_t)(negotiatedMTU - 3) : 20;
  size_t off = 0;
  while (off < (size_t)len) {
    size_t n = ((size_t)len - off < chunk) ? ((size_t)len - off) : chunk;
    txChar->setValue((uint8_t *)(buf + off), n);
    txChar->notify();
    off += n;
    if (off < (size_t)len) delay(6);
  }
}
static void blePoll() {
  if (bleNewConnect) { bleNewConnect = false; bleWasConnected = true; Serial.println("BLE central connected"); sw_claim_master_ble(); }
  else if (!bleConnected && bleWasConnected) { bleWasConnected = false; sw_ble_disconnected(); Serial.println("BLE central disconnected"); }
  int b, g = 0;
  while ((b = rxDequeue()) >= 0 && g++ < 4096) sw_process_live_byte((uint8_t)b);
}

// ===========================================================================
//  Arduino entry points (AUTOSTART_ARDUINO = n; we drive them)
// ===========================================================================
extern "C" void app_main(void) {
  initArduino();
  Serial.begin(115200);
  delay(200);
  Serial.println();
  Serial.println("=== ESP32 Firmata (Embedded Swift) : FirmataESP32 ===");
  fm_analog_setup();
  sw_system_reset();
  tcpInit();
  bleInit();
  for (;;) {
    tcpPoll();
    blePoll();
    sw_loop_tick();
    delay(1);
  }
}
