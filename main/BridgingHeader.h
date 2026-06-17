//===----------------------------------------------------------------------===//
// BridgingHeader.h — C surface the Embedded-Swift Firmata logic calls.
// Self-contained (<stdint.h> only). The I/O four (digitalWrite/digitalRead/
// analogRead/analogWrite) are Arduino's own extern "C" HAL functions, declared
// here with their exact signatures so Swift calls them directly. Everything
// fm_* is implemented in firmata_shim.cpp.
//===----------------------------------------------------------------------===//
#pragma once
#include <stdint.h>

// --- Arduino HAL I/O (called directly by Swift) ---
void     digitalWrite(uint8_t pin, uint8_t val);
int      digitalRead(uint8_t pin);
uint16_t analogRead(uint8_t pin);
void     analogWrite(uint8_t pin, int value);      // LEDC PWM, 8-bit (0..255)

// --- Pin mode + time (Arduino, via small shims) ---
void          fm_pin_mode(int pin, int mode);      // 0=INPUT 1=OUTPUT 2=INPUT_PULLUP
unsigned int  fm_millis(void);
void          fm_delay_ms(unsigned int ms);
void          fm_delay_us(unsigned int us);
void          fm_analog_setup(void);

// --- I2C (Wire) ---
void fm_i2c_begin(int sda, int scl);
void fm_i2c_begin_transmission(int addr);
void fm_i2c_write(int b);
int  fm_i2c_end_transmission(int stop);
int  fm_i2c_request_from(int addr, int count);
int  fm_i2c_available(void);
int  fm_i2c_read(void);

// --- Serial logging ---
void fm_log(const char *s);
void fm_log_host(const uint8_t *bytes, int n);

// --- Transports (Wi-Fi/TCP + BLE) ---
void fm_tcp_send(const uint8_t *buf, int len);
void fm_tcp_drop(void);
void fm_ble_send(const uint8_t *buf, int len);
void fm_ble_drop(void);
