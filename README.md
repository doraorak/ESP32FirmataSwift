# ESP32FirmataSwift

Firmata firmware for the ESP32 (Xtensa LX6), written in **Embedded Swift** on
ESP-IDF. Speaks Firmata 2.x over Wi-Fi (Bonjour/TCP), BLE (Nordic UART), and USB
serial, with an on-device task extension: registers, branches, loops, arithmetic,
HTTP + JSON inspection, strings, and tasks that spawn tasks.

## The suite

| Repo | Role |
|---|---|
| [SwiftFirmataClient](https://github.com/doraorak/SwiftFirmataClient) | macOS/iOS client package (start here for the API + COOKBOOK) |
| [ESP32FirmataSwift](https://github.com/doraorak/ESP32FirmataSwift) | This repo — the Embedded Swift firmware |
| [ESP32Firmata](https://github.com/doraorak/ESP32Firmata) | The same firmware in C++/Arduino (byte-identical wire) |

## Flash it

```bash
./flash.sh                      # sources ESP-IDF, builds, flashes
./monitor.sh                    # 115200 console — shows IP / Bonjour / BLE status
```

Override the port with `./flash.sh /dev/cu.XXXX`, the IDF path with `IDF_EXPORT=…`.
No toolchain? Each [release](https://github.com/doraorak/ESP32FirmataSwift/releases)
ships a prebuilt app image — flash it at **0x10000** with esptool, then provision
Wi-Fi from the client. The board needs 4 MB flash (3 MB app partition).

## Wi-Fi credentials

- **Compile-time**: set `WIFI_SSID` / `WIFI_PASS` at the top of
  `main/Configuration.swift` before flashing.
- **Provisioned**: leave the placeholders and send credentials from the client
  (`provisionWiFi` — encrypted X25519 + AES-GCM, over BLE, TCP, or serial). Stored
  in NVS only after a successful join; a wrong password rolls back to the previous
  network, so the board can't be stranded.

## Connecting

| Transport | Details |
|---|---|
| Wi-Fi | `_firmata._tcp` on port **3030**, instance `esp32-firmata` (TXT carries `ip`/`port`) |
| BLE | Nordic UART Service, name `Firmata-ESP32` |
| USB serial | 115200. Boots as the log console; the **first byte** a host sends claims the Firmata session and silences logging. |

One master at a time, latest wins; the evicted client gets an `EVICTED` string
notice. Scheduler tasks keep running across disconnects. The firmware reports its
name as `swiftFirmataESP32` (the C++ twin reports `FirmataESP32`).

## Building from source

Swift has no official Xtensa backend, so this uses a **custom toolchain**:
Espressif's Xtensa LLVM backend grafted into Apple's `llvm-project`, with `swiftc`
built against it. Set it up following
[georgik/swift-xtensa](https://github.com/georgik/swift-xtensa) (a one-time build
producing a `swiftc` that targets `xtensa-esp32-none-elf`). The resulting compiler
is IDF-independent — it emits a plain Xtensa `.o` that links with any IDF.

Then the usual IDF flow (5.3.2 + the `espressif__arduino-esp32` managed component):

```bash
source ~/esp/esp-idf-v5.3.2/export.sh
idf.py set-target esp32
idf.py -p /dev/cu.usbserial-XXXX flash monitor
```

## Architecture

| Layer | File(s) |
|---|---|
| Firmata parser, pin/query handlers, scheduler + task extension, modules, transport arbitration | `main/*.swift` (Embedded Swift — `Main`, `Scheduler`, `FirmataProtocol`, `Modules`, `IRModule`, `RuntimeState`, `Session`, …) |
| Arduino HAL: Wi-Fi/mDNS/TCP, BLE NUS, HTTP(S), I²C, NVS, crypto | `main/firmata_shim.cpp` (C++) |
| Swift-runtime `__atomic_*` stubs | `main/atomic_stubs.c` |

Swift calls the shim through `fm_*` functions declared in `main/BridgingHeader.h`;
C calls Swift through `sw_*` entry points. Swift owns the run loop.

## The task extension

Stored tasks make decisions on the board with nobody connected. The extension rides
under the standard scheduler's reserved `EXTENDED_SCHEDULER_COMMAND` (`0x7F`), so a
stock Firmata scheduler ignores it. Features:

- 32 global `Int32` registers + 16 floats — `R0–R15`/`F0–F7` public, `R16–R31`/`F8–F15` internal (auto-allocated destinations)
- forward-only `if`/`else` (a task can branch but never hang the board)
- a native counted **loop** (nestable 4 deep) — runs a block exactly N times
- int/float arithmetic and comparisons with float promotion
- HTTP(S) from the task; JSON/string inspection over the retained body
- a 12-slot snapshot pool (2 JSON + 10 strings) that survives later requests
- I²C register reads into registers; `sendString` telemetry to the host
- **nested tasks** — a task body may contain scheduler `CREATE/ADD/SCHEDULE/DELETE`, so tasks spawn and stop tasks

Drive it from Swift via `SwiftFirmataClient`'s `uploadTask { board in … }` — see that
repo's [COOKBOOK](https://github.com/doraorak/SwiftFirmataClient/blob/main/COOKBOOK.md).
The wire format below is the reference for other implementations.

## Wire format (ext ops)

SysEx embedded in a task's data, under `SCHEDULER_DATA` (`0x7B`) →
`EXTENDED_SCHEDULER_COMMAND` (`0x7F`). `<const>` is an Int32 as 5 Encoder7Bit bytes;
`<skip>`/`<len>`/`<count>`/`<gap>` are 14-bit little-endian 7-bit pairs;
`<path>`/`<str>`/`<url>`/`<body>` are 7-bit ASCII.

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
ARITH          F0 7B 7F 1A <subop> <dst> <operandA> <operandB>          F7  // R[dst] = A op B (int)
SET_FLOAT      F0 7B 7F 1B <fdst> <const:5>                             F7  // F[fdst] = float
ARITH_F        F0 7B 7F 1C <subop> <fdst> <operandA> <operandB>         F7  // F[fdst] = A op B (float)
JSON_FLOAT     F0 7B 7F 1D <fdst> <found> <pathLen:2> <path…>           F7  // F[fdst] = json float
JSON_TYPE      F0 7B 7F 1E <dst> <pathLen:2> <path…>                    F7  // R[dst] = type at path
JSON_SIZE      F0 7B 7F 1F <dst> <pathLen:2> <path…>                    F7  // R[dst] = span byte length
STR_LEN        F0 7B 7F 20 <dst> <pathLen:2> <path…>                    F7  // R[dst] = string length
HEAP           F0 7B 7F 21 <freeReg> <largestReg>                       F7  // heap free / largest block
BODY_GEN       F0 7B 7F 22 <dst>                                        F7  // R[dst] = response generation
SNAPSHOT       F0 7B 7F 23 <slot> <pathLen:2> <path…>                   F7  // copy value -> snapshot slot
SELECT         F0 7B 7F 24 <sel> <expGenReg>                            F7  // 0=live(gen-checked), k=snap k-1
FREE           F0 7B 7F 25 <slot>                                       F7  // free a snapshot slot
LAST_STATUS    F0 7B 7F 26 <dst>                                        F7  // R[dst] = last inspection status
CMP            F0 7B 7F 27 <op> <dst> <operandA> <operandB>             F7  // R[dst] = (A op B) ? 1 : 0
STR_BODY_LEN   F0 7B 7F 28 <dst>                                        F7  // R[dst] = selected string length
STR_EQUALS     F0 7B 7F 29 <dst> <strLen:2> <str…>                      F7  // R[dst] = (== str) ? 1 : 0
STR_INDEXOF    F0 7B 7F 2A <dst> <strLen:2> <str…>                      F7  // R[dst] = index, or -1
STR_TO_NUM     F0 7B 7F 2B <dst> <found>                                F7  // R[dst] = leading int (clamped)
JSON_GET_STR   F0 7B 7F 2C <slot> <pathLen:2> <path…>                   F7  // string content -> slot
STR_SET_SLOT   F0 7B 7F 2D <slot> <strLen:2> <str…>                     F7  // literal string -> slot
STR_COPY_SLOT  F0 7B 7F 2E <dst> <src>                                  F7  // copy slot -> slot
I2C_READ       F0 7B 7F 2F <addr> <regLo> <regHi> <count> <dst>         F7  // 1–4 bytes -> R[dst] (BE)
EMIT_STRING    F0 7B 7F 30 <lenLo> <lenHi> <bytes…>                     F7  // task -> host STRING_DATA
REG_QUERY      F0 7B 7F 31                                             F7  // reply with all registers
WRITE_PIN      F0 7B 7F 32 <kind> <pin> <operand>                       F7  // kind 0=digital, 1=analog/servo (by pin mode)
MODULE_OP      F0 7B 7F 33 <id> <payload…>                             F7  // task drives module <id>
LOOP           F0 7B 7F 34 <count:2> <gap:2> <skip:2>                   F7  // repeat body count×, gap ms between; skip if 0
LOOP_END       F0 7B 7F 35                                             F7  // back-edge to the matching LOOP
REG_REPLY      F0 7B 0C <32×5B ints> <16×5B float bits>                 F7  // device -> host snapshot
HTTP_REPLY     F0 7B 0B <status:2> <body 14-bit pairs…>                 F7  // device -> host
```

- `<reg>`: int register `0–31` (bools are 0/1 in the same bank); `<fdst>`: float
  register `0–15`. `0–15` / `0–7` are the public banks; `16–31` / `8–15` are internal
  (where value-producing ops auto-allocate their results).
- `<op>`: `0 ==` `1 !=` `2 <` `3 >` `4 <=` `5 >=`.
- `<operand>`: type byte + data — `00 <reg>` int register, `01 <const:5>` int literal,
  `02 <freg>` float register, `03 <const:5>` float literal (IEEE 754 bits). If either
  side is float, the op promotes to float.
- `<channel>` is an analog channel index (A0 = 0…), **not** a GPIO number.
- `if/else` compiles to `[IF skip=thenLen] [then…] [SKIP skip=elseLen] [else…]` — forward-only.
- `loop` compiles to `[LOOP count gap skip=bodyLen] [body…] [LOOP_END]`; `LOOP_END`
  jumps back and suspends `gap` ms between iterations; `count 0` skips the body via
  `skip`. Nests up to 4 deep.
- `HTTP`: `<method>` `0`=GET `1`=POST (`Content-Type: application/json`). Stores the
  status in `R[statusReg]` (`0` on failure) and retains the body (~4 KB cap for host
  echo; inspection walks the full body in place).
- Inspection sources: `SELECT 0` = live body (marked **stale** when
  `bodyGen != R[expGenReg]`), `k` = snapshot slot `k-1`. The pool has **12 slots** —
  JSON snapshots use `0–1`, strings `2–11`. `LAST_STATUS` codes: `0` ok, `1` notFound,
  `2` stale, `3` typeMismatch, `4` tooBig, `5` allocFailed.
- `JSON_NUM`: value at dotted/indexed `<path>` (`result[0].pct`) × 10^`<scale>`,
  truncated; parses quoted numbers; `R[found]` = 1/0.
- Arithmetic uses 64-bit intermediates; `÷0` and `%0` yield `0`. `STR_TO_NUM` clamps to Int32.
- **Nested tasks**: task bytes may themselves contain base scheduler messages
  (`CREATE 0x00` / `ADD 0x02` / `SCHEDULE 0x04` / `DELETE 0x01`), dispatched like host
  traffic. `CREATE` never hands out the slot currently being replayed, so a task can't
  replace itself mid-run.
- `REG_QUERY`/`REG_REPLY`: each value is 5 little-endian 7-bit limbs (ints as
  two's-complement bit patterns, floats as IEEE 754 bits). Works live or from a task.
- **Servo**: `SERVO_CONFIG` (`F0 70 <pin> <minLo minHi> <maxLo maxHi> F7`) sets the
  pulse range and enters servo mode; `setPinMode 0x04` uses the 544–2400 µs default.
  Writes to a servo pin mean degrees when `< 544`, pulse µs otherwise (LEDC, 50 Hz).
- Base scheduler limits: 8 task slots, 512 bytes/task, ids 0–127; a one-shot removes
  itself; a trailing `DELAY` loops the task.

## Modules

Compile-time plugins behind one reserved SysEx, **`MODULE_DATA` (`0x0D`)**, each
written in the firmware's own language — native Swift here. Wire:

- `F0 0D 00 F7` — **query**; reply `F0 0D 7F <n> [<id> <maj> <min> <nameLen> <name…>]* F7`.
- `F0 0D <id> <payload…> F7` — talk to module `<id>` (`0x01–0x7E`); the payload is that
  module's own protocol, both directions (modules push events the same way).
- Task ext op `0x33 <id> <payload…>` — a scheduled task drives a module.

Each module is a `final class` conforming to `ModuleHandler` (its `id`/version/`name`,
a `handle(_:_:)` for its wire ops, and a `tick()`); a `modules` array is the registry
that discovery, dispatch, and the per-loop tick all iterate. Adding a module is one
class plus one array entry.

| ID | Module | Purpose |
|----|--------|---------|
| `0x01` | `ir` | Infrared NEC/RC6 transmit + NEC receive over RMT |

The IR module transmits any protocol via one raw op (`0x03 <kHz> <mark/space µs pairs>`),
with NEC/RC6 encoded host-side (see [SwiftFirmataIR](https://github.com/doraorak/SwiftFirmataIR));
it also carries on-device NEC/RC6 encoders (`0x05 <protocol> <reg>`) to replay a code
held in a register. Drive the LED at 5 V, keep the receiver on 3.3 V.

## Pin map (ESP32)

- Full digital (input/pullup/output/PWM): GPIO 0, 2, 4, 5, 12–19, 21–23, 25–27, 32, 33
- Input-only: GPIO 34, 35, 36, 39 · Analog A0–A5 → GPIO 32, 33, 34, 35, 36, 39 · I²C: SDA 21 / SCL 22

## Troubleshooting

IDF 5.3.2 on Python 3.9: `check_python_dependencies.py` can spuriously fail on dotted
dist names (`ruamel.yaml`) — `pip install importlib_metadata` into the IDF venv and
pin `setuptools<81`.

## License

MIT — see [LICENSE](LICENSE).
