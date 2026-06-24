#!/usr/bin/env bash
# Build + flash the Embedded-Swift ESP32 firmware in one go.
#
#   ./flash.sh                      # auto-detects the USB port
#   ./flash.sh /dev/cu.wchusbserial110   # or name the port yourself
#
# (First build is slow — a few minutes. After that it's quick.)
set -e
cd "$(dirname "$0")"

IDF_EXPORT="${IDF_EXPORT:-$HOME/Desktop/esp-idf-v5.3.2/export.sh}"
PORT="${1:-$(ls /dev/cu.* 2>/dev/null | grep -iE 'usbserial|wchusbserial|SLAB' | head -1)}"

if [ -z "$PORT" ]; then
  echo "❌ No ESP32 serial port found. Plug the board into USB and re-run,"
  echo "   or pass it explicitly:   ./flash.sh /dev/cu.wchusbserial110"
  exit 1
fi
if [ ! -f "$IDF_EXPORT" ]; then
  echo "❌ ESP-IDF not found at: $IDF_EXPORT"
  echo "   Set the path:   IDF_EXPORT=/path/to/esp-idf/export.sh ./flash.sh"
  exit 1
fi

echo "→ Sourcing ESP-IDF…"
source "$IDF_EXPORT" >/dev/null
echo "→ Building + flashing to $PORT …"
idf.py -p "$PORT" flash
echo "✅ Flashed. To watch the boot log and find the board's IP:   ./monitor.sh"
