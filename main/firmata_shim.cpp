/* ===----------------------------------------------------------------------===//
   firmata_shim.cpp — BRIDGING ONLY.
   No implementation logic lives here. Every function is a thin wrapper over a
   vendor (Arduino / ESP-IDF) API so Embedded Swift can reach it. The protocol,
   Scheduler, logic extension, transport orchestration (Wi-Fi/Bonjour/TCP + BLE),
   arbitration and the main loop are all in Main.swift.
   Two things are unavoidably C++ and are kept to pure forwarding:
     * BLE callback classes — Swift can't subclass a C++ class, so these just
       push bytes into a FIFO / set event flags that Swift polls.
     * `app_main` — the ESP-IDF entry; it inits Arduino and calls Swift `sw_main`.
   String arguments are passed from Swift as `const uint8_t*` (StaticString /
   byte buffers) and cast to `char*` here.
   ===----------------------------------------------------------------------===// */
#include "Arduino.h"
#include "esp_log.h"
#include "WiFi.h"
#include "WiFiClientSecure.h"   // HTTPS (TLS via ssl_client / mbedTLS)
#include "HTTPClient.h"
#include "ESPmDNS.h"
#include "Wire.h"

/* IDF certificate bundle (CONFIG_MBEDTLS_CERTIFICATE_BUNDLE=y) — browser-like
   root CA set, so HTTPS certs are validated. Same approach works in the Arduino
   sketch (the core embeds the same bundle). */
extern const uint8_t fm_crt_bundle_start[] asm("_binary_x509_crt_bundle_start");
extern const uint8_t fm_crt_bundle_end[]   asm("_binary_x509_crt_bundle_end");
#include "BLEDevice.h"
#include "BLEServer.h"
#include "BLEUtils.h"
#include "BLE2902.h"

/* ==== Encrypted Wi-Fi provisioning crypto + NVS (mbedTLS + Preferences).
    Ephemeral X25519 ECDH -> HKDF-SHA256 -> AES-256-GCM. Mirrors the C++
    firmware (ESP32Firmata); Swift drives it via fm_wc_* / fm_nvs_* below.
   ==================== */
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

/* ==== Time / GPIO / ADC / Serial  (Arduino HAL passthroughs) ============ */
extern "C" {
void         fm_serial_begin(unsigned baud) { Serial.begin(baud); }

/* Console logging is gated: once a host starts speaking Firmata over USB serial,
   log lines would corrupt the binary stream, so fm_console_quiet() silences both
   our own fm_log() and the IDF/Arduino runtime logs for the rest of the session. */
static bool  fm_logs_on = true;
void         fm_console_quiet(void)         { fm_logs_on = false; esp_log_level_set("*", ESP_LOG_NONE); }
void         fm_log(const uint8_t *s)       { if (fm_logs_on) Serial.println((const char *)s); }

// Raw serial I/O for Firmata-over-USB (UART0 — the same port as the log console).
/* ==== RMT primitives for the module subsystem ============================
   1 MHz tick (1 us per duration). The shim exposes the PERIPHERAL only —
   protocol logic (e.g. the IR module's NEC encode/decode) lives with the
   module in the firmware's own language. Durations alternate mark/space. */
#include "esp32-hal-rmt.h"

static int32_t fm_rx_status = 0;   // 0 untried, 1 ok, 2 rmtInit failed, 3 readAsync failed
static int32_t fm_tx_last = -1;    // last rmtWrite result (1/0), -1 = never

int32_t fm_rmt_tx_init(int32_t pin, int32_t carrier_hz) {
  if (!rmtInit((int)pin, RMT_TX_MODE, RMT_MEM_NUM_BLOCKS_1, 1000000)) return 0;
  if (carrier_hz > 0) rmtSetCarrier((int)pin, true, false, (uint32_t)carrier_hz, 0.33f);
  return 1;
}

static int fm_tx_invert = 0;   // debug: 0 = mark HIGH/space LOW, 1 = mark LOW/space HIGH
void fm_rmt_tx_set_invert(int32_t inv) { fm_tx_invert = inv ? 1 : 0; }

void fm_rmt_tx(int32_t pin, const int32_t *durations, int32_t count) {
  static rmt_data_t sym[64];
  uint8_t markLvl  = fm_tx_invert ? 0 : 1;   // level during a "mark" (durations[even])
  uint8_t spaceLvl = fm_tx_invert ? 1 : 0;
  int n = 0;
  for (int i = 0; i < count && n < 64; i += 2) {
    uint32_t d0 = durations[i]     > 32767 ? 32767 : (uint32_t)durations[i];
    uint32_t d1 = (i + 1 < count && durations[i+1] > 0)
                  ? (durations[i+1] > 32767 ? 32767 : (uint32_t)durations[i+1]) : 1;
    sym[n].level0 = markLvl;  sym[n].duration0 = d0;
    sym[n].level1 = spaceLvl; sym[n].duration1 = d1;
    n++;
  }
  fm_tx_last = rmtWrite((int)pin, sym, n, 200) ? 1 : 0;
}

static rmt_data_t fm_rx_buf[128];   // full 2-block capacity: 256 durations
static size_t     fm_rx_len = 0;
static bool       fm_rx_armed = false;
static int        fm_rx_pin = -1;

int32_t fm_rmt_rx_init(int32_t pin) {
  if (!rmtInit((int)pin, RMT_RX_MODE, RMT_MEM_NUM_BLOCKS_2, 1000000)) { fm_rx_status = 2; return 0; }
  rmtSetRxMaxThreshold((int)pin, 12000);   // 12 ms idle ends a frame
  // Glitch filter runs on the 80 MHz source clock (8-bit, max ~255 cycles ~= 3.2 us),
  // NOT the 1 MHz resolution clock. A larger value makes rmt_receive() reject the
  // config and reception silently never starts. 2 us is safely under the limit.
  rmtSetRxMinThreshold((int)pin, 2);       // ignore sub-2 us glitches
  fm_rx_pin = (int)pin;
  fm_rx_len = sizeof(fm_rx_buf) / sizeof(fm_rx_buf[0]);
  fm_rx_armed = rmtReadAsync(fm_rx_pin, fm_rx_buf, &fm_rx_len);
  fm_rx_status = fm_rx_armed ? 1 : 3;
  return fm_rx_armed ? 1 : 0;
}

int32_t fm_rmt_rx_status(void) { return fm_rx_status; }
int32_t fm_rmt_tx_last(void)   { return fm_tx_last; }

/* Set the TX carrier (duty as 0..100 percent, freq in Hz; 0 Hz disables it). Used by
   the raw-send op to pick a per-protocol carrier, and by the live-retune debug op. */
int32_t fm_rmt_tx_carrier(int32_t pin, int32_t polarity, int32_t duty_pct, int32_t freq_hz) {
  float duty = (float)duty_pct / 100.0f;
  return rmtSetCarrier((int)pin, freq_hz > 0, polarity != 0, (uint32_t)freq_hz, duty) ? 1 : 0;
}

/* Poll for a completed capture: fills out[] with alternating durations (us),
   returns the count and re-arms; 0 when nothing has been received. */
int32_t fm_rmt_rx_poll(int32_t *out, int32_t maxCount) {
  if (!fm_rx_armed || fm_rx_pin < 0) return 0;
  if (!rmtReceiveCompleted(fm_rx_pin)) return 0;
  int n = 0;
  for (size_t i = 0; i < fm_rx_len && n + 1 < maxCount; i++) {
    out[n++] = (int32_t)fm_rx_buf[i].duration0;
    out[n++] = (int32_t)fm_rx_buf[i].duration1;
  }
  fm_rx_len = sizeof(fm_rx_buf) / sizeof(fm_rx_buf[0]);
  fm_rx_armed = rmtReadAsync(fm_rx_pin, fm_rx_buf, &fm_rx_len);
  return n;
}

/* Servo via LEDC (Arduino core 3.x API): 50 Hz, 14-bit resolution. Duty for a
   pulse of W us in a 20 ms frame = W * 2^14 / 20000. */
extern bool fm_ledc_on[];   // defined below with fm_ledc_config
void         fm_servo_attach(int32_t pin)   { ledcAttach((uint8_t)pin, 50, 14); fm_ledc_on[(uint8_t)pin] = true; }
void         fm_servo_detach(int32_t pin)   { ledcDetach((uint8_t)pin); fm_ledc_on[(uint8_t)pin] = false; }
void         fm_servo_write_us(int32_t pin, int32_t us) {
  if (us < 0) us = 0;
  uint32_t duty = (uint32_t)((uint64_t)us * 16384u / 20000u);
  if (duty > 16383u) duty = 16383u;
  ledcWrite((uint8_t)pin, duty);
}

int32_t      fm_serial_available(void)      { return (int32_t)Serial.available(); }
int32_t      fm_serial_read(void)           { return (int32_t)Serial.read(); }   // -1 when empty
void         fm_serial_write(const uint8_t *b, int32_t n) { Serial.write(b, (size_t)n); }
void         fm_analog_setup(void) {
  analogReadResolution(12);
#if defined(ADC_11db)
  analogSetAttenuation(ADC_11db);
#endif
}
void         fm_pin_mode(int pin, int mode) {   // 0=INPUT 1=OUTPUT 2=INPUT_PULLUP 3=INPUT_PULLDOWN
  pinMode((uint8_t)pin, mode == 1 ? OUTPUT
                      : (mode == 2 ? INPUT_PULLUP
                      : (mode == 3 ? INPUT_PULLDOWN : INPUT)));
}
unsigned     fm_millis(void)             { return (unsigned)millis(); }
void         fm_delay_ms(unsigned m)     { delay(m); }
void         fm_delay_us(unsigned u)     { delayMicroseconds(u); }

/* ==== ESP32 pin-mode extensions ========================================== */
int32_t      fm_touch_read(int32_t pin)  { return (int32_t)touchRead((uint8_t)pin); }
void         fm_dac_write(int32_t pin, int32_t v) {
  if (v < 0) v = 0;
  if (v > 255) v = 255;
  dacWrite((uint8_t)pin, (uint8_t)v);
}
/* PWM_CONFIG pins bypass the Arduino core's LEDC layer entirely: the core's
   analogWrite* / ledcChangeFrequency retune paths proved flaky on hardware
   (different melody notes died on different runs). Each configured pin gets
   its own IDF-direct LOW-SPEED timer+channel, allocated from the TOP of the
   range so the core's own bottom-up allocation (servo, plain .pwm analogWrite)
   never collides until 12+ simultaneous channels. Retune = ledc_set_freq only.
   (fm_ledc_on above is the servo ledger for the core-managed channels.) */
#include "driver/ledc.h"
#define FM_LEDC_SLOTS 4
static int fm_ledc_pin[FM_LEDC_SLOTS] = { -1, -1, -1, -1 };
static int fm_ledc_res[FM_LEDC_SLOTS] = { 8, 8, 8, 8 };
static int fm_ledc_slot_of(int pin) {
  for (int i = 0; i < FM_LEDC_SLOTS; i++) if (fm_ledc_pin[i] == pin) return i;
  return -1;
}
static void fm_ledc_timer_init(int slot, int32_t freq_hz, int32_t res_bits) {
  ledc_timer_config_t t = {};
  t.speed_mode      = LEDC_LOW_SPEED_MODE;
  t.duty_resolution = (ledc_timer_bit_t)res_bits;
  t.timer_num       = (ledc_timer_t)(3 - slot);
  t.freq_hz         = (uint32_t)freq_hz;
  t.clk_cfg         = LEDC_AUTO_CLK;
  ledc_timer_config(&t);
}
bool fm_ledc_on[SOC_GPIO_PIN_COUNT] = { false };
void         fm_ledc_config(int32_t pin, int32_t freq_hz, int32_t res_bits) {
  if (res_bits < 1) res_bits = 1;
  if (res_bits > 14) res_bits = 14;
  int slot = fm_ledc_slot_of((int)pin);
  if (slot < 0) {                                      // first config: claim a slot
    for (int i = 0; i < FM_LEDC_SLOTS; i++) if (fm_ledc_pin[i] < 0) { slot = i; break; }
    if (slot < 0) return;                              // all 4 slots busy
    fm_ledc_pin[slot] = (int)pin;
    fm_ledc_res[slot] = (int)res_bits;
    fm_ledc_timer_init(slot, freq_hz, res_bits);
    ledc_channel_config_t c = {};
    c.gpio_num   = (int)pin;
    c.speed_mode = LEDC_LOW_SPEED_MODE;
    c.channel    = (ledc_channel_t)(7 - slot);
    c.intr_type  = LEDC_INTR_DISABLE;
    c.timer_sel  = (ledc_timer_t)(3 - slot);
    c.duty       = 0;
    c.hpoint     = 0;
    ledc_channel_config(&c);
  } else if ((int)res_bits != fm_ledc_res[slot]) {     // resolution change: re-init timer
    fm_ledc_res[slot] = (int)res_bits;
    fm_ledc_timer_init(slot, freq_hz, res_bits);
  } else {                                             // retune only — deterministic
    ledc_set_freq(LEDC_LOW_SPEED_MODE, (ledc_timer_t)(3 - slot), (uint32_t)freq_hz);
  }
}

/* Duty write that routes PWM_CONFIG-managed pins to their IDF channel and
   everything else through the Arduino core's analogWrite. */
void         fm_pwm_write(int32_t pin, int32_t duty) {
  int slot = fm_ledc_slot_of((int)pin);
  if (slot >= 0) {
    // duty == max -> write max+1: LEDC's constant-high point (true 100%, no spike train)
    uint32_t d = (uint32_t)duty;
    uint32_t max = (1u << fm_ledc_res[slot]) - 1u;
    if (d >= max) d = max + 1u;
    ledc_set_duty(LEDC_LOW_SPEED_MODE, (ledc_channel_t)(7 - slot), d);
    ledc_update_duty(LEDC_LOW_SPEED_MODE, (ledc_channel_t)(7 - slot));
  } else {
    analogWrite((uint8_t)pin, (int)duty);
  }
}

/* ==== Module hardware primitives (sonar / DHT) =========================== */
/* HC-SR04: 10 us trigger pulse, then measure the echo-high width. Blocking up
   to timeout_us (~25 ms at 4 m) — acceptable once per handle()/tick(). */
int32_t      fm_sonar_ping_us(int32_t trig, int32_t echo, int32_t timeout_us) {
  digitalWrite((uint8_t)trig, LOW);  delayMicroseconds(2);
  digitalWrite((uint8_t)trig, HIGH); delayMicroseconds(10);
  digitalWrite((uint8_t)trig, LOW);
  unsigned long us = pulseIn((uint8_t)echo, HIGH, (unsigned long)timeout_us);
  return (int32_t)us;                       // 0 on timeout
}

/* DHT11/22 bit-bang read (type 0=DHT11, 1=DHT22). 40 bits, bit value decided by
   the high-pulse width (~26-28 us = 0, ~70 us = 1). Returns 0 ok, -1 fail.
   Timing-critical: the line release and every sample use DIRECT GPIO registers
   (Arduino pinMode/digitalRead can burn >100 us in peripheral bookkeeping, which
   desynchronises the 26-70 us bit stream), and the whole ~4 ms window runs with
   interrupts masked. Direct-register path covers GPIO 0-31 (use those pins). */
#include "soc/gpio_struct.h"
static inline int dhtLvl(uint32_t bit) { return (GPIO.in & bit) ? 1 : 0; }
static int dhtWaitBit(uint32_t bit, int level, uint32_t timeout_us) {
  uint32_t t0 = micros();
  while (dhtLvl(bit) != level) {
    if ((uint32_t)(micros() - t0) > timeout_us) return -1;
  }
  return (int)(uint32_t)(micros() - t0);
}
int32_t      fm_dht_read(int32_t pin32, int32_t type, float *temp_c, float *hum_pct) {
  if (pin32 < 0 || pin32 >= 32) return -1;             // direct-reg path: GPIO 0-31
  uint8_t pin = (uint8_t)pin32;
  uint32_t bit = 1UL << pin;
  uint8_t data[5] = {0, 0, 0, 0, 0};

  // Configure pull-up once; drive the start signal via direct output-enable.
  pinMode(pin, INPUT_PULLUP);
  GPIO.out_w1tc = bit;                                 // latched LOW when output enables
  GPIO.enable_w1ts = bit;                              // drive low (start signal)
  delay(20);                                           // >=18 ms covers DHT11 and DHT22

  static portMUX_TYPE dhtMux = portMUX_INITIALIZER_UNLOCKED;
  bool fail = false;
  taskENTER_CRITICAL(&dhtMux);
  GPIO.enable_w1tc = bit;                              // release: pull-up snaps high (~ns)
  // Sensor response: low within 20-40 us, then ~80 us low / ~80 us high, then 40 bits.
  if (dhtWaitBit(bit, 0, 90)  < 0 ||
      dhtWaitBit(bit, 1, 120) < 0 ||
      dhtWaitBit(bit, 0, 120) < 0) {
    fail = true;
  } else {
    for (int i = 0; i < 40; i++) {
      if (dhtWaitBit(bit, 1, 80) < 0) { fail = true; break; }        // ~50 us low preamble
      int high = dhtWaitBit(bit, 0, 110);                            // bit = high-pulse width
      if (high < 0) { fail = true; break; }
      data[i / 8] <<= 1;
      if (high > 45) data[i / 8] |= 1;                               // ~26 us = 0, ~70 us = 1
    }
  }
  taskEXIT_CRITICAL(&dhtMux);
  if (fail) return -1;
  if ((uint8_t)(data[0] + data[1] + data[2] + data[3]) != data[4]) return -1;

  if (type == 0) {                                     // DHT11: integral bytes
    *hum_pct = (float)data[0] + (float)data[1] * 0.1f;
    *temp_c  = (float)data[2] + (float)(data[3] & 0x7F) * 0.1f;
  } else {                                             // DHT22: 10ths, sign bit on temp
    *hum_pct = ((float)(((uint16_t)data[0] << 8) | data[1])) * 0.1f;
    float t  = ((float)(((uint16_t)(data[2] & 0x7F) << 8) | data[3])) * 0.1f;
    *temp_c  = (data[2] & 0x80) ? -t : t;
  }
  return 0;
}

// I2C (Wire)
void fm_i2c_begin(int sda, int scl)       { Wire.begin((uint8_t)sda, (uint8_t)scl); }
void fm_i2c_begin_transmission(int addr)  { Wire.beginTransmission((uint8_t)addr); }
void fm_i2c_write(int b)                  { Wire.write((uint8_t)b); }
int  fm_i2c_end_transmission(int stop)    { return Wire.endTransmission((bool)stop); }
int  fm_i2c_request_from(int addr, int n) { return Wire.requestFrom(addr, n); }
int  fm_i2c_available(void)               { return Wire.available(); }
int  fm_i2c_read(void)                    { return Wire.read(); }

/* ==== Wi-Fi / mDNS  (each call is one vendor API; Swift sequences them) ==== */
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

/* ==== HTTP client  (Arduino HTTPClient over Wi-Fi; Swift sequences the call and
    decides what to do with the result). Response body is held here until the
    next request; Swift copies it out via fm_http_resp_len / fm_http_resp_copy.
   ==================== */
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

/* ---- JSON snapshot slots: owned copies of a response (sub)value that survive
        the next request. Grow-only buffers (realloc only when bigger) to avoid
        heap-fragmenting churn. Stable pointers so Swift can walk them in place. */
#define FM_NUM_SNAP 12
static uint8_t *fm_snap[FM_NUM_SNAP]    = {nullptr};   // rest zero-initialised
static int      fm_snapCap[FM_NUM_SNAP] = {0};
static int      fm_snapLen[FM_NUM_SNAP] = {0};
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

/* ==== TCP server / client  (one vendor op each; Swift drives accept/read/write) ==== */
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

/* ==== BLE Nordic UART Service.
    Callbacks are pure forwarders into a FIFO / event flags that Swift polls —
    no protocol/transport logic here. (Swift can't subclass these C++ classes.)
   ==================== */
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

/* ==== ESP-IDF entry — init Arduino, hand everything to Swift. =========== */
void app_main(void) { initArduino(); sw_main(); }
} // extern "C"
