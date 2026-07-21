/* ===----------------------------------------------------------------------===//
   BridgingHeader.h — the vendor-API surface Embedded Swift calls.
   All of these are thin bridges implemented in firmata_shim.cpp (no logic),
   except the four Arduino HAL I/O functions, which Swift calls directly.
   String arguments are passed as `const uint8_t*` (StaticString / byte buffers).
   ===----------------------------------------------------------------------===// */
#pragma once
#include <stdint.h>

// --- Arduino HAL I/O (called directly by Swift) ---
void     digitalWrite(uint8_t pin, uint8_t val);
int      digitalRead(uint8_t pin);
uint16_t analogRead(uint8_t pin);
void     analogWrite(uint8_t pin, int value);

// --- Time / GPIO / ADC / Serial ---
void          fm_serial_begin(unsigned baud);
void          fm_log(const uint8_t *s);
void          fm_console_quiet(void);
int32_t       fm_rmt_tx_init(int32_t pin, int32_t carrier_hz);
void          fm_rmt_tx(int32_t pin, const int32_t *durations, int32_t count);
int32_t       fm_rmt_rx_init(int32_t pin);
int32_t       fm_rmt_rx_poll(int32_t *out, int32_t maxCount);
int32_t       fm_rmt_rx_status(void);
int32_t       fm_rmt_tx_last(void);
int32_t       fm_rmt_tx_carrier(int32_t pin, int32_t polarity, int32_t duty_pct, int32_t freq_hz);
void          fm_rmt_tx_set_invert(int32_t inv);
void          fm_servo_attach(int32_t pin);
void          fm_servo_detach(int32_t pin);
void          fm_servo_write_us(int32_t pin, int32_t us);
int32_t       fm_serial_available(void);
int32_t       fm_serial_read(void);
void          fm_serial_write(const uint8_t *b, int32_t n);
void          fm_analog_setup(void);
void          fm_pin_mode(int pin, int mode);        // 0=INPUT 1=OUTPUT 2=INPUT_PULLUP 3=INPUT_PULLDOWN
unsigned int  fm_millis(void);
void          fm_delay_ms(unsigned int ms);
void          fm_delay_us(unsigned int us);

// --- ESP32 pin-mode extensions (touch / DAC / LEDC config) ---
int32_t       fm_touch_read(int32_t pin);                            // raw touch counts (lower = touched)
float         fm_log10f(float x);                                     // libm log10f (mic dB math)
int           fm_i2s_mic_begin(int bclk, int ws, int sd, int sampleRate);  // I2S MEMS mic (INMP441); 1=ok
float         fm_i2s_mic_rms(void);                                   // DC-removed RMS of an I2S block
int32_t       fm_i2s_mic_peak_raw(void);                             // largest raw 32-bit sample (diagnostic)
float         fm_i2s_mic_dominant_hz(int sampleRate);                // FFT dominant frequency, Hz (0=no tone)
void          fm_dac_write(int32_t pin, int32_t value);              // true analog out, 0-255 (GPIO 25/26)
void          fm_ledc_config(int32_t pin, int32_t freq_hz, int32_t res_bits); // per-pin PWM freq/resolution
void          fm_pwm_write(int32_t pin, int32_t duty);              // duty write (IDF channel for PWM_CONFIG pins)

// --- Module hardware primitives (sonar / DHT) ---
int32_t       fm_sonar_ping_us(int32_t trig, int32_t echo, int32_t timeout_us); // echo pulse width us, 0 = timeout
int32_t       fm_dht_read(int32_t pin, int32_t type, float *temp_c, float *hum_pct); // 0 ok, -1 fail; type 0=DHT11 1=DHT22

// --- I2C (Wire) ---
void fm_i2c_begin(int sda, int scl);
void fm_i2c_begin_transmission(int addr);
void fm_i2c_write(int b);
int  fm_i2c_end_transmission(int stop);
int  fm_i2c_request_from(int addr, int count);
int  fm_i2c_available(void);
int  fm_i2c_read(void);

// --- Wi-Fi / mDNS ---
void fm_wifi_begin(const uint8_t *ssid, const uint8_t *pass, const uint8_t *host);
int  fm_wifi_connected(void);
int  fm_wifi_same_network(const uint8_t *ssid, const uint8_t *pass);
int  fm_wifi_localip(uint8_t *out, int n);
int  fm_mdns_begin(const uint8_t *host);
void fm_mdns_add_service(const uint8_t *svc, const uint8_t *proto, int port);
void fm_mdns_add_txt(const uint8_t *svc, const uint8_t *proto, const uint8_t *k, const uint8_t *v);

// --- HTTP client (over Wi-Fi) ---
int fm_http_request(const uint8_t *url, int is_post, const uint8_t *body, const uint8_t *content_type);
int fm_http_resp_len(void);
const uint8_t *fm_http_resp_ptr(void);
int fm_http_resp_copy(uint8_t *dst, int max);
int fm_free_heap(void);
int fm_largest_free_block(void);
int fm_snapshot_copy(int slot, const uint8_t *src, int len);
const uint8_t *fm_snapshot_ptr(int slot);
int fm_snapshot_len(int slot);
void fm_snapshot_free(int slot);

// --- TCP server / client ---
void fm_tcp_begin(int port);
int  fm_tcp_poll_new(void);
void fm_tcp_promote(void);
int  fm_tcp_connected(void);
int  fm_tcp_available(void);
int  fm_tcp_read(void);
void fm_tcp_write(const uint8_t *buf, int len);
void fm_tcp_drop(void);

// --- Encrypted Wi-Fi provisioning (X25519 ECDH + HKDF-SHA256 + AES-256-GCM, NVS) ---
int  fm_wc_begin(uint8_t *out_pub32);                                   // 1 ok / 0 fail
int  fm_wc_derive_key(const uint8_t *peer_pub32, uint8_t *out_key32);   // one-shot
int  fm_wc_gcm_decrypt(const uint8_t *key32, const uint8_t *nonce12,
                       const uint8_t *ct, int ctlen, const uint8_t *tag16, uint8_t *out_pt);
int  fm_nvs_load_creds(uint8_t *ssid, int ssid_cap, uint8_t *pass, int pass_cap);
void fm_nvs_save_creds(const uint8_t *ssid, const uint8_t *pass);
void fm_nvs_clear_creds(void);

// --- BLE Nordic UART Service ---
void fm_ble_begin(const uint8_t *name);
int  fm_ble_connected(void);
int  fm_ble_mtu(void);
void fm_ble_notify(const uint8_t *buf, int len);
void fm_ble_drop(void);
int  fm_ble_poll_connect(void);
int  fm_ble_poll_disconnect(void);
int  fm_ble_rx_pop(void);
