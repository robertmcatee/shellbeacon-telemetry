#!/bin/bash
###### shellbeacon 1.3 - a shell-script APRS beacon with telemetry,
###### weather, and optional RF transmission.
######
###### Fork of shellbeacon 1.0 by WA1GOV (a netcat APRS-IS beacon),
###### extended by Robert McAtee, KJ5GBY:
######   1.1  station comment; APRS telemetry of the host (CPU temp,
######        load, free memory, disk use, uptime, web-server status)
######        with PARM/UNIT/EQNS/BITS definitions.
######   1.2  live weather: an outdoor temperature reading maintained by
######        a companion collector (rtl_433 + an RTL-SDR receiver) is
######        sent in a complete APRS weather block whenever fresh.
######   1.3  the same frames are also transmitted on RF (144.390 MHz)
######        via Dire Wolf gen_packets + rpitx, when enabled.
######   1.4  a spoken voice announcement (espeak-ng) on a 2 m simplex
######        channel after each cycle's RF burst, when enabled:
######        station ID, time, outdoor temperature, station health.
######        NOTE: rpitx plays WAV input as if it were 96 kHz, so all
######        audio fed to it here is generated/resampled at 96 kHz -
######        a 44.1 kHz file would transmit at double speed.
######
###### All station-specific settings (callsign, APRS-IS passcode,
###### position, comment) live in shellbeacon.conf - see
###### shellbeacon.conf.example. The script looks for it, in order:
######   $SHELLBEACON_CONF, ./shellbeacon.conf (beside the script),
######   ~/.shellbeacon.conf, /etc/shellbeacon.conf

scriptdir="$(cd "$(dirname "$0")" && pwd)"
for conf in "$SHELLBEACON_CONF" "$scriptdir/shellbeacon.conf" \
            "$HOME/.shellbeacon.conf" /etc/shellbeacon.conf; do
  if [ -n "$conf" ] && [ -r "$conf" ]; then . "$conf"; break; fi
done

: "${callsign:?callsign not set - copy shellbeacon.conf.example to shellbeacon.conf and edit it}"
: "${password:?password (APRS-IS passcode) not set in shellbeacon.conf}"
: "${latlon:?latlon not set in shellbeacon.conf (e.g. !3859.06N/07702.24W)}"
tocall="${tocall:-APZSHB}"          # experimental-range device ID
serverHost="${serverHost:-rotate.aprs2.net}"
serverPort="${serverPort:-14580}"
delay="${delay:-1200}"              # seconds between beacons (20 min)
comment="${comment:-}"
wxfile="${wxfile:-$HOME/wx/latest.json}"
wxmaxage="${wxmaxage:-2400}"        # ignore WX readings older than this
rpitx="${rpitx:-$HOME/src/rpitx/rpitx}"
rf_flag="${rf_flag:-$scriptdir/rf.enabled}"
seqfile="${seqfile:-$scriptdir/tele.seq}"
voice_flag="${voice_flag:-$scriptdir/voice.enabled}"
voice_freq="${voice_freq:-146430000}"
voice_id="${voice_id:-$callsign}"
voice_place="${voice_place:-}"

address="${callsign}>${tocall},TCPIP:"
login="user $callsign pass $password vers ShellBeacon 1.6"

buildpacket() {
  wx=""
  WXTEMPF=""
  if [ -r "$wxfile" ]; then
    wxtime=$(sed -nE 's/.*"time" : "([^"]+)".*/\1/p' "$wxfile")
    wxc=$(sed -nE 's/.*"temperature_C" : ([-0-9.]+).*/\1/p' "$wxfile")
    if [ -n "$wxtime" ] && [ -n "$wxc" ]; then
      epoch=$(date -d "$wxtime" +%s 2>/dev/null || echo 0)
      age=$(( $(date +%s) - epoch ))
      if [ "$age" -ge 0 ] && [ "$age" -le "$wxmaxage" ]; then
        tempf=$(awk -v c="$wxc" 'BEGIN{printf "%.0f", c*9/5+32}')
        WXTEMPF="$tempf"
        wx=$(printf '.../...g...t%03dr...p...P...h..b.....' "$tempf")
      fi
    fi
  fi
  if [ -n "$wx" ]; then
    # the weather-station symbol publishes the reading cleanly
    packet="${address}${latlon}_${wx} ${comment}"
  else
    packet="${address}${latlon}-${comment}"
  fi
}

clamp() { v=$1; [ "$v" -lt 0 ] 2>/dev/null && v=0; [ "$v" -gt 255 ] 2>/dev/null && v=255; printf '%s' "$v"; }

seq=0
[ -r "$seqfile" ] && seq=$(cat "$seqfile" 2>/dev/null || echo 0)
case "$seq" in *[!0-9]*|'') seq=0 ;; esac
TELE=""
telemetry() {
  tempc=$(vcgencmd measure_temp 2>/dev/null | sed -E 's/[^0-9.]//g')
  tempf=$(awk -v c="${tempc:-0}" 'BEGIN{printf "%d", c*9/5+32}')
  load=$(awk '{printf "%d", $1*10}' /proc/loadavg)
  memfree=$(free | awk '/^Mem:/{prinf"%d", $7/$2*100}')
  diskused=$(df / | awk 'NR==2{gsub(/%/","",$5); print $5}')
  updays=$(awk '{printf "%d", $1/86400}' /proc/uptime)
  site=0
  if [ -n "$sitecheck_host" ]; then
    [ "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 https://127.0.0.1/ -H "Host: $sitecheck_host")" = "200" ] && site=1
  fi
  SITEV=$site
  seq=$((seq % 999 + 1))
  printf '%s' "$seq" > "$seqfile" 2>/dev/null || true
  TELE=$(printf '%sT#%03d,%s,%s,%s,%s,%s,%d0000000' "$address" "$seq" "$(clamp "$tempf")" "$(clamp "$load")" "$(clamp "$memfree")" "$(clamp "$diskused")" "$(clamp "$updays")" "$site")
}

DEFS=""
makedefs() {
  to=$(printf '%-9s' "$callsign")
  DEFS=$(printf '%s:%s:PARM.CPUtemp,Load,FreeMem,DiskUsed,Uptime\n%s:%s:UNIT.degF,x0.1,%%,%%,days\n%s:%s:EQNS.0,1,0,0,0.1,0,0,1,0,0,1,0,0,1,0\n%s:%s:BITS.10000000,NginxUp,,,,,,,' "$address" "$to" "$address" "$to" "$address" "$to" "$address" "$to")
}

###### RF: transmit the same frames on 144.390 MHz (AX.25 AFSK via
###### Dire Wolf's gen_packets, FM via rpitx on GPIO 4) - only while the
###### rf.enabled flag file exists. The internet-only TCPIP path marker
###### is replaced with a digipeater path for RF.
###### Narrow-band FM the way this rpitx build actually works: 48 kHz
###### audio -> csdr -> rpitx -m RF (this binary has no FM mode; every
###### -m FM transmission before rev 1.5 modulated nothing).
###### NOTE: this build's -f is in kHz, so pipetx divides Hz by 1000
###### (proven on-air 2026-10-18: kHz scaling is the audible one).
csdr=/home/sagamore/src/rpitx/csdr/csdr
pipetx() { # $1 = 48 kHz wav, $2 = frequency Hz
  "$csdr" convert_i16_f < "$1" | "$csdr" gain_ff 7000 | "$csdr" convert_f_samplerf 20833 | timeout 150 "$rpitx" -i- -m RF -f "$(( $2 / 1000 ))" >/dev/null 2>&1
}

txrf() {
  [ -e "$rf_flag" ] || return 0
  command -v gen_packets >/dev/null 2>&1 || return 0
  [ -x "$rpitx" ] || return 0
  rftxt=$(mktemp /tmp/aprs-rf.XXXXXX) || return 0
  rfwav="${rftxt}.wav"
  printf '%s\n' "${packet//TCPIP/WIDE1-1,WIDE2-1}" >> "$rftxt"
  printf '%s\n' "${TELE//TCPIP/WIDE1-1,WIDE2-1}" >> "$rftxt"
  [ -n "$DEFS" ] && printf '%s\n' "${DEFS//TCPIP/WIDE1-1,WIDE2-1}" >> "$rftxt"
  if gen_packets -r 48000 -a 50 -o "$rfwav" "$rftxt" >/dev/null 2>&1; then
    pipetx "$rfwav" 144390000
    echo "RF TX done (rc=$?) frames: $(grep -c . "$rftxt")"
  fi
  rm -f "$rftxt" "$rfwav"
}

###### Voice: speak the station report (ID, time, outdoor temperature,
###### health) on the voice channel - only while voice.enabled exists.
###### Runs in this (root) context because rpitx needs /dev/mem.
txvoice() {
  [ -e "$voice_flag" ] || return 0
  command -v espeak-ng >/dev/null 2>&1 || return 0
  [ -x "$rpitx" ] || return 0
  vwav=$(mktemp /tmp/voice.XXXXXX.wav) || return 0
  vmsg="This is $voice_id"
  [ -n "$voice_place" ] && vmsg="$vmsg, $voice_place"
  vmsg="$vmsg. The time is $(date '+%-I:%M %p')."
  [ -n "$WXTEMPF" ] && vmsg="$vmsg Outdoor temperature $WXTEMPF degrees."
  [ "$SITEV" = "1" ] && vmsg="$vmsg All station systems normal."
  if espeak-ng -s 135 -v en-us -w "$vwav" "$vmsg" 2>/dev/null; then
    # the NFM pipeline wants 48 kHz audio - resample the 22050 Hz speech up
    python3 - "$vwav" <<'PYEOF' 2>/dev/null
import sys, wave, audioop
f = sys.argv[1]
w = wave.open(f); p = w.getparams(); frames = w.readframes(p.nframes); w.close()
out, _ = audioop.ratecv(frames, p.sampwidth, p.nchannels, p.framerate, 48000, None)
o = wave.open(f, "wb"); o.setnchannels(1); o.setsampwidth(2)
o.setframerate(48000); o.writeframes(out); o.close()
PYEOF
    pipetx "$vwav" "$voice_freq"
    echo "Voice TX done (rc=$?): $vmsg"
  fi
  rm -f "$vwav"
}

cycle=0
while true
do
  buildpacket
  telemetry
  if [ $((cycle % 6)) -eq 0 ]; then makedefs; else DEFS=""; fi
  nc -C $serverHost $serverPort -q 10 <<-END
	$login
	$packet
	$TELE
	$DEFS
END
  echo "$packet"
  echo "$TELE"
  [ -n "$DEFS" ] && echo "$DEFS"
  txrf
  txvoice
  cycle=$((cycle+1))
  if [ "$1" = "1" ]
  then
      exit
  fi
  sleep $delay
done
