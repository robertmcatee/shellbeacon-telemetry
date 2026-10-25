#!/bin/bash
# One-shot verification: a single Tidewater announcement WITH the place
# fragment, on 146.430 MHz, built from LIVE station state. This exercises
# the exact sentence the live beacon speaks (callsign + place + time +
# temp + health). Run as root (rpitx needs /dev/mem). The beacon service
# should be paused during the window, as with the other voice tests.
CSDR=/home/sagamore/src/rpitx/csdr/csdr
RPITX=/home/sagamore/src/rpitx/rpitx
FRAG=/var/aprs-beacon
LOG=/home/sagamore/voice-test-tide-place.log
: > "$LOG"

pipetx() { # $1 = 48 kHz wav, $2 = frequency Hz
  "$CSDR" convert_i16_f < "$1" | "$CSDR" gain_ff 7000 | "$CSDR" convert_f_samplerf 20833 | timeout 150 "$RPITX" -i- -m RF -f "$(( $2 / 1000 ))" >/dev/null 2>&1
}

# Live temp, same rule as buildpacket(): age <= 2400 s, C -> F rounded.
wxfile=/home/sagamore/wx/latest.json
tempf=""
if [ -r "$wxfile" ]; then
  wxtime=$(sed -nE 's/.*"time" : "([^"]+)".*/\1/p' "$wxfile")
  wxc=$(sed -nE 's/.*"temperature_C" : ([-0-9.]+).*/\1/p' "$wxfile")
  if [ -n "$wxtime" ] && [ -n "$wxc" ]; then
    epoch=$(date -d "$wxtime" +%s 2>/dev/null || echo 0)
    age=$(( $(date +%s) - epoch ))
    if [ "$age" -ge 0 ] && [ "$age" -le 2400 ]; then
      tempf=$(awk -v c="$wxc" 'BEGIN{printf "%.0f", c*9/5+32}')
    fi
  fi
fi
site=0
[ "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 https://127.0.0.1/ -H 'Host: www.cenzontle.us')" = "200" ] && site=1

hour=$(date '+%-I'); minute=$(date '+%-M'); ampm=$(date '+%p')
args=(--dir "$FRAG" --prefix voice-tidewater --place-token san-antonio-texas --out /tmp/voice-test-tide-place.wav --hour "$hour" --minute "$minute" --ampm "$ampm")
[ -n "$tempf" ] && args+=(--temp "$tempf" --wx-ok)
[ "$site" = "1" ] && args+=(--web-ok)
sentence=$(python3 "$FRAG/voice-say.py" "${args[@]}")
echo "$(date '+%H:%M:%S') place shot: $sentence (temp=${tempf:-none} site=$site)" >> "$LOG"
if [ -s /tmp/voice-test-tide-place.wav ]; then
  pipetx /tmp/voice-test-tide-place.wav 146430000
  echo "$(date '+%H:%M:%S') place shot TX done" >> "$LOG"
else
  echo "$(date '+%H:%M:%S') place shot SKIPPED: no WAV built, nothing transmitted" >> "$LOG"
fi
rm -f /tmp/voice-test-tide-place.wav
echo "$(date '+%H:%M:%S') place shot done" >> "$LOG"
