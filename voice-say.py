#!/usr/bin/env python3
"""Assemble a KJ5GBY voice announcement from pre-rendered fragments.

Usage:
  voice-say.py --dir FRAGDIR --out OUT.wav --hour H --minute M --ampm AM|PM
               [--temp TEMP] [--wx-ok] [--web-ok] [--place TEXT]

Builds exactly the sentence shellbeacon.sh's txvoice() speaks, but from
WAV fragments (Piper voice) instead of a live TTS engine:
  "This is KJ5GBY. The time is <hour> <minute> <AM|PM>.
   [Outdoor temperature <temp> degrees.]
   [All station systems normal. | Weather system is down.
    Web server is down.]"

Rules, mirroring txvoice():
  - --temp omitted means no temperature is spoken and the weather
    system counts as down.
  - If --place is given, the script exits 2: a place name has no
    fragment, so the caller should fall back to espeak for the whole
    message rather than speak half of it.
  - Output is a 48 kHz mono 16-bit WAV, ready for pipetx().
  - Pure standard library: no audioop (removed in Python 3.13, which
    is what trixie ships), so this works on bookworm and trixie alike.
  - Fragments are joined with 90 ms of silence and 5 ms fades at each
    join to avoid clicks.
"""
import argparse
import array
import sys
import wave
from pathlib import Path

SR_OUT = 48000
SIL_MS = 90
FADE_MS = 5

ONES = ["zero", "one", "two", "three", "four", "five", "six", "seven",
        "eight", "nine"]
TEENS = ["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
         "sixteen", "seventeen", "eighteen", "nineteen"]
TENS = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
        "eighty", "ninety"]


def number_words(n):
    """Integer 0..99 -> fragment tokens."""
    if n < 10:
        return [ONES[n]]
    if n < 20:
        return [TEENS[n - 10]]
    toks = [TENS[n // 10]]
    if n % 10:
        toks.append(ONES[n % 10])
    return toks


def minute_words(m):
    """Minute 0..59 -> fragment tokens, as spoken after the hour."""
    if m == 0:
        return ["oclock"]
    if m < 10:
        return ["oh", ONES[m]]
    return number_words(m)


def temp_words(t):
    """Temperature string like '72.4' or '-2.5' -> fragment tokens."""
    neg = t.startswith("-")
    if neg:
        t = t[1:]
    whole, _, frac = t.partition(".")
    toks = (["minus"] if neg else []) + number_words(int(whole))
    if frac:
        toks.append("point")
        toks.extend(ONES[int(d)] for d in frac)
    return toks


def load_fragment(directory, token, prefix="voice-amy"):
    path = Path(directory) / f"{prefix}-{token}.wav"
    if not path.exists():
        raise FileNotFoundError(f"missing fragment: {path}")
    with wave.open(str(path), "rb") as w:
        if w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise ValueError(f"unexpected fragment format: {path}")
        rate = w.getframerate()
        frames = w.readframes(w.getnframes())
    samples = array.array("h")
    samples.frombytes(frames)
    if rate != SR_OUT:
        # Fallback for legacy 22050 Hz fragments: resample this one
        # fragment only. 48 kHz fragments (the shipped set) pass
        # through untouched, so assembly is pure concatenation.
        n_out = int(len(samples) * SR_OUT / rate)
        res = array.array("h", [0]) * n_out
        for i in range(n_out):
            pos = i * rate / SR_OUT
            j = int(pos)
            frac = pos - j
            a = samples[j] if j < len(samples) else 0
            b = samples[j + 1] if j + 1 < len(samples) else 0
            res[i] = int(a + (b - a) * frac)
        return res
    return samples


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True, help="fragment directory")
    ap.add_argument("--out", required=True, help="output WAV path")
    ap.add_argument("--hour", type=int, required=True)
    ap.add_argument("--minute", type=int, required=True)
    ap.add_argument("--ampm", choices=["AM", "PM"], required=True)
    ap.add_argument("--temp", default=None, help="e.g. 72.4; omit = no temp")
    ap.add_argument("--wx-ok", action="store_true")
    ap.add_argument("--web-ok", action="store_true")
    ap.add_argument("--place", default=None)
    ap.add_argument("--place-token", default=None,
                    help="fragment token for a known place, spoken after the callsign")
    ap.add_argument("--prefix", default="voice-amy",
                    help="fragment filename prefix (default voice-amy)")
    args = ap.parse_args()

    if args.place:
        print("voice-say: place name has no fragment; fall back to espeak",
              file=sys.stderr)
        return 2
    if not 1 <= args.hour <= 12 or not 0 <= args.minute <= 59:
        print("voice-say: hour/minute out of range", file=sys.stderr)
        return 2

    # hour 10/11/12 come from TEENS (10, 11, 12); hours 1-9 from ONES
    tokens = ["this-is-kj5gby"]
    if args.place_token:
        tokens.append(args.place_token)
    tokens.append("the-time-is")
    if args.hour <= 9:
        tokens.append(ONES[args.hour])
    else:
        tokens.append(TEENS[args.hour - 10])
    tokens += minute_words(args.minute)
    tokens.append("am" if args.ampm == "AM" else "pm")

    wx_ok = args.wx_ok and args.temp is not None
    if args.temp is not None:
        tokens.append("outdoor-temperature")
        tokens += temp_words(args.temp)
        tokens.append("degrees")
    if wx_ok and args.web_ok:
        tokens.append("all-station-systems-normal")
    else:
        if not wx_ok:
            tokens.append("weather-system-is-down")
        if not args.web_ok:
            tokens.append("web-server-is-down")

    sil = array.array("h", [0] * int(SR_OUT * SIL_MS / 1000))
    fade = int(SR_OUT * FADE_MS / 1000)
    out = array.array("h")
    for i, tok in enumerate(tokens):
        frag = load_fragment(args.dir, tok, args.prefix)
        for j in range(min(fade, len(frag))):
            frag[j] = int(frag[j] * j / fade)
            frag[-1 - j] = int(frag[-1 - j] * j / fade)
        out.extend(frag)
        if i < len(tokens) - 1:
            out.extend(sil)

    with wave.open(args.out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR_OUT)
        w.writeframes(out.tobytes())
    print(" ".join(t.replace("-", " ") for t in tokens))
    return 0


if __name__ == "__main__":
    sys.exit(main())
