# ESP32FirmataSwift — ESP32Firmata in Embedded Swift

A faithful, section-by-section port of the original cpp
[**ESP32Firmata**](https://github.com/doraorak/ESP32Firmata) (Firmata 2.x
firmware) to **Embedded Swift**, running on the **original ESP32 (Xtensa LX6)**.

The Firmata protocol, the Scheduler, and the on-device register / `if` / `else`
logic extension are all written in Embedded Swift; the Arduino peripheral APIs
and both transports — **Wi-Fi/TCP + Bonjour** and **BLE (Nordic UART Service)**,
running simultaneously with **latest-wins** arbitration — are reached through a
thin C/C++ interop shim. There is no serial transport (the cpp firmware has none).

It speaks the exact same wire protocol as the cpp firmware, so it works with the
[**SwiftFirmataClient**](https://github.com/doraorak/SwiftFirmataClient) package
(Bonjour or BLE) and with standard Firmata hosts.

---

## 1. Set up Embedded Swift for the ESP32 (Xtensa)

Upstream Swift's Embedded mode supports the RISC-V ESP32s but **not** the
Xtensa ESP32, because the official Swift toolchain's LLVM has no Xtensa backend.
You need a **custom Swift toolchain** that grafts Espressif's Xtensa LLVM backend
into Apple's `swiftlang/llvm-project`, then builds `swiftc` against it.

### 1a. Build the toolchain (~once, a few hours)

```bash
brew install cmake ninja
# clone the build workspace (Swift + Apple-LLVM-with-Xtensa + cmark + swift-syntax)
git clone https://github.com/georgik/swift-xtensa.git
cd swift-xtensa
./swift-xtensa-build-script.sh        # produces ./install/bin/swiftc
```

`swiftc` then cross-compiles Embedded Swift to Xtensa:

```bash
install/bin/swiftc -target xtensa-esp32-none-elf \
    -enable-experimental-feature Embedded -wmo -parse-as-library -Osize \
    -c Main.swift -o Main.o            # -> ELF 32-bit Tensilica Xtensa object
```

The hard parts (all handled by the build script / patches): the Xtensa
**datalayout must match byte-for-byte** between Clang and the LLVM backend; Clang's
**default `TargetCodeGenInfo` must provide a `SwiftABIInfo`**; Swift IRGen must use
the **static relocation model** (Xtensa rejects PIC); the embedded unicode stubs
need `-fno-pic`; and on a modern macOS you must build under the **Command Line
Tools** SDK (clang 17), not a too-new Xcode.

> Drop this project inside the `swift-xtensa` workspace (so `../../install`
> resolves), or edit `SWIFTC` in `main/CMakeLists.txt` to point at your
> `install/bin/swiftc`.

### 1b. ESP-IDF + arduino-esp32

This project uses the Arduino APIs as an ESP-IDF component, and **arduino-esp32
is locked to specific ESP-IDF versions** (3.1.x ⇒ IDF 5.3). So install
**ESP-IDF v5.3.2** and the build uses **arduino-esp32 3.1.3** (pinned in
`main/idf_component.yml`):

```bash
git clone -b v5.3.2 --recursive https://github.com/espressif/esp-idf.git ~/esp/esp-idf-v5.3.2
~/esp/esp-idf-v5.3.2/install.sh esp32
```

> The Swift toolchain is IDF-independent (it just emits an Xtensa `.o` that links
> with any IDF), so toolchain (any IDF) and firmware (IDF 5.3.2) can differ.
> If the IDF Python env is on Python 3.9, see *Troubleshooting* below.

## 2. Build & flash

The board needs **4 MB flash** (Wi-Fi + BLE + Arduino + Swift is large; this uses
a 3 MB app partition — `partitions.csv`).

```bash
source ~/esp/esp-idf-v5.3.2/export.sh
cd ESP32FirmataSwift
# set your Wi-Fi creds in main/Main.swift (WIFI_SSID / WIFI_PASS)
idf.py set-target esp32
idf.py -p /dev/cu.usbserial-XXXX flash monitor   # 115200 console shows IP / Bonjour / BLE
```

## 3. How the Swift ↔ C/C++ split works

| Layer | File | Language |
|---|---|---|
| Firmata parser, message builders, pin handlers, capability/analog-mapping/pin-state | [`main/Main.swift`](main/Main.swift) | **Embedded Swift** |
| I2C request/reply logic; **Scheduler** (Encoder7Bit); **register / `if` / `else` logic extension**; dual-transport arbitration | `main/Main.swift` | **Embedded Swift** |
| Arduino `pinMode` / `digitalWrite` / `digitalRead` / `analogRead` / `analogWrite`, `Wire`, `Serial` | [`main/firmata_shim.cpp`](main/firmata_shim.cpp) | C++ interop |
| Wi-Fi/TCP + ESPmDNS (Bonjour) and BLE NUS transports | `main/firmata_shim.cpp` | C++ interop |
| `__atomic_*` helpers the Swift runtime needs | `main/atomic_stubs.c` | C |

`digitalWrite` / `digitalRead` / `analogRead` / `analogWrite` are Arduino's own
`extern "C"` HAL functions — Swift calls them directly (declared in
`main/BridgingHeader.h`). C++ calls Swift via `sw_*` entry points; Swift calls
hardware/transport via `fm_*` functions and the Arduino I/O four.

## 4. Connecting

* **Bonjour / Wi-Fi** — `_firmata._tcp` on port **3030** (TXT `ip`/`port`). Matches `BonjourTransport`.
* **BLE** — Nordic UART Service `6E400001-…`, name `Firmata-ESP32`. Matches `BLETransport`.

Firmware reports name **`FirmataESP32`**, protocol/firmware **v2.8**. Connecting
on one transport evicts the other (latest-wins); queued Scheduler tasks keep
running across disconnects.

---

## 5. Custom protocol — Scheduler logic extension

On top of the Firmata Scheduler, a stored task can make decisions on the board
(thermostat, night-light, …) with nobody connected: **16 global Int32 registers**
`R0`–`R15`, reads into registers, and `if`/`else`. Forward-only branching, so a
task can branch but can't hang the board. It rides under the reference scheduler's
reserved `EXTENDED_SCHEDULER_COMMAND` (`0x7F`), so a standard scheduler ignores it
gracefully.

### High-level API (SwiftFirmataClient)

```swift
try await client.uploadTask(id: 3, repeatEveryMs: 1000) { t in
    t.setPinMode(2, mode: .output)
    t.readAnalog(into: 0, channel: 0)              // R0 = analogRead(A0)
    t.ifTrue(.reg(0), .lessThan, .const(300),      // if dark
        then:   { $0.digitalWrite(pin: 2, value: true) },   // LED on
        elseDo: { $0.digitalWrite(pin: 2, value: false) })
}
```

`setRegister(_:to:)`, `readDigital(into:pin:)`, `readAnalog(into:channel:)`,
`ifTrue(_:_:_:then:elseDo:)` (operands `.reg(0...15)`/`.const`, ops `== != < > <= >=`).

### Internet actions

A task can reach the internet over the board's Wi-Fi (Arduino `HTTPClient` /
`WiFiClientSecure`, bridged in `firmata_shim.cpp`; orchestration in `Main.swift`).
It makes an HTTP(S) request, stores the **status** in a register, **retains the
response body** on-device, and pulls values out of it with the inspection ops —
so the device acts on web data (a stock quote, a JSON field, …) autonomously:

```swift
try await client.uploadTask(id: 5, repeatEveryMs: 60_000) { t in
    t.setPinMode(2, mode: .output)
    t.httpGet("https://example.com/quote/SPY", statusInto: 0)
    let pct = t.jsonNumber("changePercent", scaledBy: 2)   // -0.42 -> -42
    t.ifTrue(pct, .greaterThan, .const(0),
        then:   { $0.digitalWrite(pin: 2, high: true) },
        elseDo: { $0.digitalWrite(pin: 2, high: false) })
}
// or live, awaiting the result and decoding it on the host:
let r = try await client.httpGet("https://jsonplaceholder.typicode.com/todos/1")
```

The request **blocks the loop** until it completes (≈8 s max). When a host is
connected, the full status + body also come back as `httpResponse(status:body:)`.

**`https://` works** with on-device certificate validation: the Arduino
`WiFiClientSecure` (`ssl_client` + mbedTLS) validates against the IDF root-CA
bundle. Two `sdkconfig` settings make this link/validate — both are in
`sdkconfig.defaults`:

* `CONFIG_MBEDTLS_PSK_MODES=y` + `CONFIG_MBEDTLS_KEY_EXCHANGE_PSK=y` — Arduino's
  `ssl_client.cpp` compiles its body **only** when a PSK key exchange is enabled
  (it `#warning`s out otherwise); without this `WiFiClientSecure` fails to link.
* `CONFIG_MBEDTLS_CERTIFICATE_BUNDLE=y` — the root-CA set used to validate certs.

### Byte commands (wire format)

SysEx embedded in a task's data, under `SCHEDULER_DATA` (`0x7B`) →
`EXTENDED_SCHEDULER_COMMAND` (`0x7F`). `<const>` is an Int32 as 5 Encoder7Bit
bytes; `<skip>` is a 14-bit count, little-endian 7-bit (`skipLo skipHi`). `<len>`
fields are 14-bit LE (`lo hi`); `<path>`/`<str>`/`<url>`/`<body>` are 7-bit ASCII.

```
SET            F0 7B 7F 10 <reg> <const:5>                          F7  // R[reg] = const
READ_DIGITAL   F0 7B 7F 11 <reg> <pin>                              F7  // R[reg] = digitalRead(pin)
READ_ANALOG    F0 7B 7F 12 <reg> <channel>                          F7  // R[reg] = analogRead(channel)
IF             F0 7B 7F 13 <op> <operandA> <operandB> <skip:2>      F7  // if !(A op B): pos += skip
SKIP           F0 7B 7F 14 <skip:2>                                 F7  // pos += skip (else)
HTTP           F0 7B 7F 15 <method> <statusReg> <urlLen:2> <url…> <bodyLen:2> <body…> F7
JSON_NUM       F0 7B 7F 16 <dst> <found> <scale> <pathLen:2> <path…>     F7
JSON_STR_EQ    F0 7B 7F 17 <dst> <pathLen:2> <path…> <strLen:2> <str…>   F7
BODY_CONTAINS  F0 7B 7F 18 <dst> <strLen:2> <str…>                       F7
JSON_STR_CONT  F0 7B 7F 19 <dst> <pathLen:2> <path…> <strLen:2> <str…>   F7
HTTP_REPLY     F0 7B 0B <status:2> <body 14-bit pairs…>                  F7  // device -> host
```

* `<reg>`: register index, low nibble (`0`–`15`).
* `<op>`: `0 ==`, `1 !=`, `2 <`, `3 >`, `4 <=`, `5 >=`.
* `<operand>`: type byte then data — `00 <reg>` (register) or `01 <const:5>` (literal).
* `<channel>`: analog channel index (A0 = 0…), **not** a pin.
* `if`/`else`: `[IF skip=thenLen] [then…] [SKIP skip=elseLen] [else…]`.
* `HTTP` (`0x15`): `<method>` `0`=GET `1`=POST. Sets `R[statusReg]`=HTTP status
  (`0` on failure) and retains the body for the inspection ops. POST sends
  `Content-Type: application/json`.
* `JSON_NUM` (`0x16`): `R[dst]` = number at `<path>` × 10^`<scale>` (truncated),
  `R[found]` = `1`/`0`. `<path>` is dotted/indexed, e.g. `result[0].changePercent`.
* `JSON_STR_EQ`/`JSON_STR_CONT` (`0x17`/`0x19`): `R[dst]` = `1`/`0` from comparing
  the JSON string at `<path>`. `BODY_CONTAINS` (`0x18`): `R[dst]` = `1`/`0`
  substring search over the whole body.
* `HTTP_REPLY` carries the status (`lo hi`) + body (14-bit pairs, up to ~4 KB)
  back to a connected host.

Base Scheduler messages (`CREATE_TASK` `0x00`, `ADD_TO_TASK` `0x02`,
`SCHEDULE_TASK` `0x04`, `DELAY_TASK` `0x03`, `QUERY` `0x05`/`0x06`, `RESET` `0x07`)
are unchanged from standard Firmata.

---

## Pin map (ESP32)

* Full digital (INPUT/PULLUP/OUTPUT/PWM): GPIO 0, 2, 4, 5, 12–19, 21–23, 25–27, 32, 33
* Input-only: GPIO 34, 35, 36, 39 · Analog A0–A5: GPIO 32, 33, 34, 35, 36, 39 · I2C: SDA 21 / SCL 22

## Troubleshooting (IDF 5.3.2 Python env on Python 3.9)

`check_python_dependencies.py` uses stdlib `importlib.metadata`, which on Python
3.9 can't resolve dotted dist names (`ruamel.yaml`) and spuriously fails the
requirements check. Fix: `pip install importlib_metadata` into the IDF venv and
make that script prefer it; also pin `setuptools<81` (81 removed `pkg_resources`).
The managed-component `REQUIRES` name is `espressif__arduino-esp32`.

## License

MIT (matches the upstream ESP32Firmata / SwiftFirmataClient projects).
