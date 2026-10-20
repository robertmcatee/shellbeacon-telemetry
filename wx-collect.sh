#!/bin/bash
# wx-collect.sh - keep the latest patio-sensor reading in ~/wx/latest.json
# Sensor: Acurite-606TX protocol (Better Homes & Gardens clone).
# Matched by model only: the sensor re-IDs at every battery swap
# (id 142 -> 29 on 2026-10-19), so an ID filter silently breaks WX.
# Runs rtl_433 and filters its JSON stream to that sensor model.
mkdir -p "$HOME/wx"
exec 9>/tmp/wx-collect.lock
flock -n 9 || exit 0
while true; do
  rtl_433 -f 433.92M -F json 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      *'"Acurite-606TX"'*)
        printf '%s\n' "$line" > "$HOME/wx/latest.json.tmp"
        mv "$HOME/wx/latest.json.tmp" "$HOME/wx/latest.json"
        ;;
    esac
  done
  sleep 10
done
