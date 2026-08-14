#!/usr/bin/env python3
"""Nightscout reading for the Omarchy bar.

Ported from a waybar module. The fetch, threshold, and sensor-expiry
reasoning is unchanged; what changed is the output contract. Waybar wanted
one pre-rendered pill (text + Pango tooltip + CSS classes), so this printed
presentation. The Quickshell widget renders its own pill and popup, so this
prints structured data instead and leaves formatting to the QML -- with the
exception of duration strings, which stay here so both surfaces phrase an
age the same way.

Every deployment-specific value is an argument with a neutral default, so
the plugin ships nothing site-specific: the widget passes the user's
shell.json settings through on each call. There is no site URL baked in --
without one this reports `unconfigured` rather than guessing.

Thresholds are NOT defined here. They are read from Nightscout's own
/api/v1/status.json so the server stays the single source of truth --
change them there and every client follows. Nightscout publishes them in
mg/dL, and the properties endpoint returns raw mgdl alongside the
display-scaled value, so classification happens in mg/dL and no unit
conversion is needed anywhere.

A read-only token is sent when --token-file exists. A site running
AUTH_DEFAULT_ROLES=readable needs no credential at all, so the token is
optional by design: a missing file must not break the bar, and sending one
when present means locking the site down to `denied` needs no change here.
Keep that file outside any directory a dotfile manager syncs -- a
credential does not belong in a pushed repo.

Sensor expiry is NOT published by every uploader. Juggluco, for one,
forwards only the sensor serial (in each entry's `device` field) and posts
no Sensor Start/Change treatments. So expiry is derived: the oldest reading
carrying a given serial is that sensor's first post-warmup reading, which
dates the activation. Uploaders that backfill history on connect make this
hold for sensors that predate the Nightscout install. Pass --sensor-days 0
where the derivation does not apply (a site whose uploader posts real
sensor treatments, or a sensor with no fixed wear time).

Output is a single JSON object on stdout, always exit 0:

    {"state": "ok",
     "text": "11.7 →",                 # what the bar pill paints
     "classes": ["high"],              # glucose class, + sensor class if any
     "url": "https://...",
     "glucose": {"shown", "mgdl", "arrow", "delta", "ageMins", "ageLabel"},
     "sensor":  {"tracked", "serial", "known", "startMs", "expiryMs", "days",
                 "ageLabel", "leftLabel", "leftSecs", "fraction"}}

    {"state": "error", "text": "⚠️ ?", "classes": ["error"],
     "title": "Nightscout unreachable", "detail": "TimeoutError: ..."}

    {"state": "unconfigured", "text": "⚠️ NS", "classes": ["error"],
     "title": "No Nightscout URL", "detail": "..."}
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

DEFAULT_TOKEN_FILE = "~/.config/nightscout-token"

# Only used if the server has never been reachable. Nightscout's own defaults.
FALLBACK = {"bgLow": 55, "bgTargetBottom": 70, "bgTargetTop": 180, "bgHigh": 260}

# Thresholds change rarely; don't refetch them every tick.
CACHE_TTL = 1800

CACHE_DIR = os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache"))

opts = None


def emit(payload):
    print(json.dumps(payload))
    sys.exit(0)


def fail(title, detail, text="⚠️ Error", state="error"):
    emit({"state": state, "text": text, "classes": ["error"],
          "url": opts.url if opts else "", "title": title, "detail": detail})


def cache_path(kind):
    """Per-site cache file. Two sites must not share a threshold cache."""
    host = urllib.parse.urlparse(opts.url).netloc or "default"
    slug = re.sub(r"[^A-Za-z0-9]+", "-", host).strip("-").lower()
    return os.path.join(CACHE_DIR, f"omarchy-nightscout-{kind}-{slug}.json")


def read_cache(path):
    with open(path) as f:
        return json.load(f)


def write_cache(path, value):
    """Atomic, and never fatal: an uncached run is slow, not wrong."""
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(value, f)
        os.replace(tmp, path)
    except OSError:
        pass


def token():
    """The read-only access token, or None if there isn't one."""
    try:
        return open(os.path.expanduser(opts.token_file)).read().strip() or None
    except OSError:
        return None


def get_json(path):
    url = f"{opts.url}{path}"
    tok = token()
    if tok:
        # Some paths already carry a query string, so the separator depends.
        url += ("&" if "?" in path else "?") + f"token={tok}"
    with urllib.request.urlopen(url, timeout=opts.timeout) as r:
        return json.load(r)


def thresholds():
    """Server thresholds, cached. Falls back to a stale cache, then to defaults."""
    path = cache_path("thresholds")
    try:
        if time.time() - os.path.getmtime(path) < CACHE_TTL:
            return read_cache(path)
    except (OSError, ValueError):
        pass

    try:
        th = get_json("/api/v1/status.json")["settings"]["thresholds"]
        # only trust a complete set
        if all(k in th for k in FALLBACK):
            write_cache(path, th)
            return th
    except Exception:
        pass

    try:  # server down: a stale cache still beats guessing
        return read_cache(path)
    except (OSError, ValueError):
        return FALLBACK


def sensor_start(serial):
    """Activation time (epoch secs) of `serial`, or None if it can't be found.

    Cached by serial: a hit costs nothing, a miss costs one full-history scan.
    """
    path = cache_path("sensor")
    try:
        c = read_cache(path)
        if c.get("serial") == serial:
            return c["start"]
    except (OSError, ValueError, KeyError):
        pass

    try:
        rows = get_json(
            f"/api/v1/entries.json?find[device]={urllib.parse.quote(serial)}"
            f"&find[date][$gte]=0&count=50000"
        )
        first = min(r["date"] for r in rows if r.get("date"))
    except (Exception, ValueError):  # network, empty result, malformed rows
        return None

    start = first / 1000 - opts.warmup_mins * 60
    write_cache(path, {"serial": serial, "start": start})
    return start


def human_dur(secs):
    secs = round(secs / 60) * 60  # else 7h59m reads as "7h"
    d, rem = divmod(secs, 86400)
    h, m = divmod(rem, 3600)[0], (rem % 3600) // 60
    if d:
        return f"{d}d {h}h"
    if h:
        return f"{h}h"
    return f"{m}m"


def parse_args():
    ap = argparse.ArgumentParser(
        description="Emit a Nightscout glucose reading as JSON for the Omarchy bar.")
    ap.add_argument("--url", default=os.environ.get("NIGHTSCOUT_URL", ""),
                    help="Nightscout base URL (env: NIGHTSCOUT_URL)")
    ap.add_argument("--token-file", default=DEFAULT_TOKEN_FILE,
                    help=f"file holding a read-only access token (default: {DEFAULT_TOKEN_FILE})")
    ap.add_argument("--timeout", type=float, default=4,
                    help="HTTP timeout in seconds (default: 4)")
    ap.add_argument("--stale-mins", type=int, default=5,
                    help="minutes without a reading before the feed counts as stale (default: 5)")
    ap.add_argument("--sensor-days", type=float, default=0,
                    help="sensor wear time in days; 0 disables sensor tracking (default: 0)")
    ap.add_argument("--warmup-mins", type=int, default=60,
                    help="minutes of warmup before a sensor's first reading (default: 60)")
    ap.add_argument("--warn-hours", type=float, default=24,
                    help="hours of remaining wear at which to warn (default: 24)")
    args = ap.parse_args()
    args.url = args.url.rstrip("/")
    return args


def main():
    global opts
    opts = parse_args()

    if not opts.url:
        fail("No Nightscout URL",
             "Set `url` on this widget's entry in ~/.config/omarchy/shell.json.",
             "⚠️ URL Missing", 
             "unconfigured")

    try:
        data = get_json("/api/v2/properties/bgnow,delta,direction")
    except Exception as e:
        fail("Nightscout unreachable",
             f"{type(e).__name__}: {e}",
             "⚠️ Nightscout unreachable")

    try:
        sgv = data["bgnow"]["sgvs"][0]
        mgdl = float(sgv["mgdl"])
        shown = str(sgv["scaled"])  # already in the server's display units
        mills = data["bgnow"]["mills"]
        arrow = data.get("direction", {}).get("label") or ""
        delta = data.get("delta", {}).get("display") or "?"
    except (KeyError, IndexError, ValueError, TypeError):
        fail("No recent readings", "Nightscout returned no glucose entries",
             text="⚠️ Readings")

    th = thresholds()
    age_mins = int((time.time() - mills / 1000) / 60)

    if age_mins >= opts.stale_mins:
        cls = "stale"
    elif mgdl < th["bgLow"]:
        cls = "urgent-low"
    elif mgdl < th["bgTargetBottom"]:
        cls = "low"
    elif mgdl >= th["bgHigh"]:
        cls = "urgent-high"
    elif mgdl >= th["bgTargetTop"]:
        cls = "high"
    else:
        cls = "in-range"

    text = f"{shown} {arrow}".strip()
    classes = [cls]

    serial = sgv.get("device", "unknown")
    tracked = opts.sensor_days > 0
    sensor = {"tracked": tracked, "serial": serial, "known": False,
              "days": opts.sensor_days}

    start = sensor_start(serial) if tracked and serial != "unknown" else None
    if start:
        now = time.time()
        wear = opts.sensor_days * 86400
        expiry = start + wear
        left = expiry - now
        sensor.update({
            "known": True,
            "startMs": int(start * 1000),
            "expiryMs": int(expiry * 1000),
            "ageLabel": human_dur(now - start),
            "leftSecs": int(left),
            "leftLabel": human_dur(abs(left)),
            # Clamped so an overdue sensor paints a full rail, not an overflow.
            "fraction": min(1.0, max(0.0, (now - start) / wear)),
        })
        if left <= 0:
            # Deliberately additive: the glucose class still applies, so a low
            # reading is never visually masked by a sensor warning.
            classes.append("sensor-expired")
            text += "   expired"
        elif left <= opts.warn_hours * 3600:
            classes.append("sensor-expiring")
            text += f"   {human_dur(left)}"

    emit({
        "state": "ok",
        "text": text,
        "classes": classes,
        # Echoed so the widget's "open Nightscout" action lands on the same
        # site this reading came from, without the URL being configured twice.
        "url": opts.url,
        "glucose": {
            "shown": shown,
            "mgdl": mgdl,
            "arrow": arrow,
            "delta": delta,
            "ageMins": age_mins,
            "ageLabel": "just now" if age_mins < 1 else f"{age_mins} min ago",
        },
        "sensor": sensor,
    })


if __name__ == "__main__":
    main()
