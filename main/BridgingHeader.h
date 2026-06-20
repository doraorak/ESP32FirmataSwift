//===----------------------------------------------------------------------===//
// BridgingHeader.h — the vendor-API surface Embedded Swift calls.
// All of these are thin bridges implemented in firmata_shim.cpp (no logic),
// except the four Arduino HAL I/O functions, which Swift calls directly.
// String arguments are passed as `const uint8_t*` (StaticString / byte buffers).
//===----------------------------------------------------------------------===//
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
void          fm_analog_setup(void);
void          fm_pin_mode(int pin, int mode);        // 0=INPUT 1=OUTPUT 2=INPUT_PULLUP
unsigned int  fm_millis(void);
void          fm_delay_ms(unsigned int ms);
void          fm_delay_us(unsigned int us);

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
int  fm_wifi_localip(uint8_t *out, int n);
int  fm_mdns_begin(const uint8_t *host);
void fm_mdns_add_service(const uint8_t *svc, const uint8_t *proto, int port);
void fm_mdns_add_txt(const uint8_t *svc, const uint8_t *proto, const uint8_t *k, const uint8_t *v);

// --- HTTP client (over Wi-Fi) ---
int fm_http_request(const uint8_t *url, int is_post, const uint8_t *body, const uint8_t *content_type);
int fm_http_resp_len(void);
int fm_http_resp_copy(uint8_t *dst, int max);

// --- TCP server / client ---
void fm_tcp_begin(int port);
int  fm_tcp_poll_new(void);
void fm_tcp_promote(void);
int  fm_tcp_connected(void);
int  fm_tcp_available(void);
int  fm_tcp_read(void);
void fm_tcp_write(const uint8_t *buf, int len);
void fm_tcp_drop(void);

// --- BLE Nordic UART Service ---
void fm_ble_begin(const uint8_t *name);
int  fm_ble_connected(void);
int  fm_ble_mtu(void);
void fm_ble_notify(const uint8_t *buf, int len);
void fm_ble_drop(void);
int  fm_ble_poll_connect(void);
int  fm_ble_poll_disconnect(void);
int  fm_ble_rx_pop(void);
