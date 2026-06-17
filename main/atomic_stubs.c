//===----------------------------------------------------------------------===//
// atomic_stubs.c — 32-bit __atomic_* helpers the Embedded Swift runtime may
// reference. (The Arduino/full-newlib build provides libc string functions, so
// unlike the bare-metal demo we do NOT override strlen/strcpy/etc. here.)
//===----------------------------------------------------------------------===//
#include <stdint.h>
#include <stdbool.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

unsigned int __atomic_load_4(const volatile void *ptr, int memorder) {
    portDISABLE_INTERRUPTS();
    unsigned int r = *(const volatile unsigned int *)ptr;
    portENABLE_INTERRUPTS();
    return r;
}

void __atomic_store_4(volatile void *ptr, unsigned int val, int memorder) {
    portDISABLE_INTERRUPTS();
    *(volatile unsigned int *)ptr = val;
    portENABLE_INTERRUPTS();
}

unsigned int __atomic_fetch_add_4(volatile void *ptr, unsigned int val, int memorder) {
    portDISABLE_INTERRUPTS();
    unsigned int r = *(volatile unsigned int *)ptr;
    *(volatile unsigned int *)ptr = r + val;
    portENABLE_INTERRUPTS();
    return r;
}

unsigned int __atomic_fetch_sub_4(volatile void *ptr, unsigned int val, int memorder) {
    portDISABLE_INTERRUPTS();
    unsigned int r = *(volatile unsigned int *)ptr;
    *(volatile unsigned int *)ptr = r - val;
    portENABLE_INTERRUPTS();
    return r;
}

bool __atomic_compare_exchange_4(volatile void *ptr, void *expected, unsigned int desired,
                                 bool weak, int smo, int fmo) {
    portDISABLE_INTERRUPTS();
    unsigned int cur = *(volatile unsigned int *)ptr;
    unsigned int exp = *(unsigned int *)expected;
    bool ok = (cur == exp);
    if (ok) *(volatile unsigned int *)ptr = desired;
    else    *(unsigned int *)expected = cur;
    portENABLE_INTERRUPTS();
    return ok;
}
