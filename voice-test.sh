#!/bin/bash
# Voice test: 3 Amy announcements on 146.430 MHz, ~60 s apart.
# Builds each announcement from LIVE station state (time, patio temp
# from the WX collector, web health probe) using voice-say.py, then
# transmits the 48 kHz WAV through the same csdr/rpitx chain txvoice()
# uses. Run as root (rpitx needs /dev/mem). No APRS packets, no
# 144.390 transmissions, no WX collector interference.
CSDR=/home/sagamore/src/rpitx/csdr/csdr
RPITX=/home/sagamore/src/rpitx/rpitx
FRAG=/var/aprs-beacon
LOG=/home/sagamore/voice-test.log
: > "$LOG"

pipetx() { # $1 = 48 kHz wav, $2 = frequency Hz
  "$CSDR" convert_i16_f < "$1" | "$CSDR" gain_ff 7000 | "$CSDR" convert_f_samplerf 20833 | timeout 150 "$RPITX" -i- -m RF -f "$(( $2 / 1000 ))" >/dev/null 2>&1
}

for shot in 1 2 3; do
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
  args=(--dir "$FRAG" --out /tmp/voice-test.wav --hour "$hour" --minute "$minute" --ampm "$ampm")
  [ -n "$tempf" ] && args+=(--temp "$tempf" --wx-ok)
  [ "$site" = "1" ] && args+=(--web-ok)
  sentence=$(python3 "$FRAG/voice-say.py" "${args[@]}")
  echo "$(date '+%H:%M:%S') shot $shot: $sentence (temp=${tempf:-none} site=$site)" >> "$LOG"
  if [ -s /tmp/voice-test.wav ]; then
    pipetx /tmp/voice-test.wav 146430000
    echo "$(date '+%H:%M:%S') shot $shot TX done" >> "$LOG"
  else
    echo "$(date '+%H:%M:%S') shot $shot SKIPPED: no WAV built, nothing transmitted" >> "$LOG"
  fi
  [ "$shot" -lt 3 ] && sleep 60
done
rm -f /tmp/voice-test.wav
echo "$(date '+%H:%M:%S') all shots done" >> "$LOG"
