#!/usr/bin/env bash
# Watch the serial log (boot messages, Wi-Fi IP, Bonjour). Press Ctrl-] to quit.
#
#   ./monitor.sh                    # auto-detects the USB port
#   ./monitor.sh /dev/cu.wchusbserial110
set -e
cd "$(dirname "$0")"

IDF_EXPORT="${IDF_EXPORT:-$HOME/Desktop/esp-idf-v5.3.2/export.sh}"
PORT="${1:-$(ls /dev/cu.* 2>/dev/null | grep -iE 'usbserial|wchusbserial|SLAB' | head -1)}"
[ -z "$PORT" ] && { echo "❌ No ESP32 serial port found."; exit 1; }

source "$IDF_EXPORT" >/dev/null
echo "→ Monitoring $PORT.  Press Ctrl-]  to quit."
idf.py -p "$PORT" monitor
