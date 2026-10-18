#!/bin/bash
# wx-collect.sh - keep the latest patio-sensor reading in ~/wx/latest.json
# Sensor: Acurite-606TX protocol, id 142 (Better Homes & Gardens clone).
# Runs rtl_433 and filters its JSON stream to that one device.
mkdir -p "$HOME/wx"
exec 9>/tmp/wx-collect.lock
flock -n 9 || exit 0
while true; do
  rtl_433 -f 433.92M -F json 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      *'"Acurite-606TX"'*'"id" : 142'*)
        printf '%s\n' "$line" > "$HOME/wx/latest.json.tmp"
        mv "$HOME/wx/latest.json.tmp" "$HOME/wx/latest.json"
        ;;
    esac
  done
  sleep 10
done
