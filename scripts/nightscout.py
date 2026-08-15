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

That token is only ever sent over a transport that can carry it safely:
https, or a loopback address, where there is no wire to listen on. Plain
http to anywhere else refuses to run rather than broadcasting the token --
and the glucose data behind it -- to whoever shares the network. Pass
--allow-insecure-auth to override that on a network you trust. The rule
is about the credential, not the site: a `readable` site with no token
polls over plain http exactly as before.

The token travels in the query string, which is not this widget's choice:
`?token=` is the only credential Nightscout's v1 and v2 endpoints accept.
Their `Authorization: Bearer` support is real but api/v3-only, and it
wants a JWT from /api/v2/authorization/request/<token> rather than the
access token itself -- a raw token in a Bearer header is a 401 on every
version. Verified against 15.0.7: with a valid token, `?token=` fills in
`authorized` while a Bearer JWT leaves it null on v1 and v2.

Moving to api/v3 to get the header would not help, because api/v3 has no
equivalent of the two things this widget reads. The thresholds live in v1
/api/v1/status.json under settings.thresholds and are simply absent from
/api/v3/status, and /api/v2/properties has no v3 counterpart at all
(/api/v3/properties is a 404), so the display-scaled value, the delta
string, and the direction arrow would all have to be recomputed here from
raw sgv -- reintroducing the unit handling this module exists to avoid.
A v3 port would still need a `?token=` call to v1 for thresholds, so the
credential would end up in a URL regardless.

So the query string is where it has to go, and the thing keeping it safe
is the transport rule above, not its placement in the request.

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

    {"state": "unconfigured", "text": "⚠️ Insecure", "classes": ["error"],
     "title": "Insecure Nightscout URL", "detail": "..."}
"""

import argparse
import ipaddress
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_TOKEN_FILE = "~/.config/nightscout-token"

# Stands in for a port urlparse refuses to read, so it compares unequal to a
# real one and reaches the URL check in main() as a value rather than a raise.
INVALID_PORT = "invalid"

# Only used if the server has never been reachable. Nightscout's own defaults.
FALLBACK = {"bgLow": 55, "bgTargetBottom": 70, "bgTargetTop": 180, "bgHigh": 260}

# Thresholds change rarely; don't refetch them every tick.
CACHE_TTL = 1800

CACHE_DIR = os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache"))

opts = None


def emit(payload):
    print(json.dumps(payload))
    sys.exit(0)


def scrub(text):
    """Strip the token out of anything user-visible.

    `detail` is rendered in the popup and is the kind of string that ends up
    pasted into a bug report. Most urllib errors don't quote the URL, but
    `ValueError: unknown url type: '<url>'` does, which is enough to leak a
    token that was riding in the query string.
    """
    tok = token()
    if not tok:
        return text
    return text.replace(urllib.parse.quote(tok, safe=""), "***").replace(tok, "***")


def fail(title, detail, text="⚠️ Error", state="error"):
    emit({"state": state, "text": text, "classes": ["error"],
          "url": opts.url if opts else "", "title": title,
          "detail": scrub(detail), "insecureAuth": insecure_auth_active()})


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


_TOKEN_UNREAD = object()
_token_cache = _TOKEN_UNREAD


def token():
    """The read-only access token, or None if there isn't one."""
    global _token_cache
    if opts is None:  # scrub() runs on any failure path, including an early one
        return None
    if _token_cache is _TOKEN_UNREAD:
        try:
            _token_cache = open(
                os.path.expanduser(opts.token_file)).read().strip() or None
        except OSError:
            _token_cache = None
    return _token_cache


def origin(url):
    """(scheme, host, port), the unit a credential must not cross.

    The port is read defensively because urlparse defers validating it until
    the attribute is touched, and this runs on the redirect path too: a junk
    port has to come back as a configuration error, not a traceback that
    breaks the one-JSON-object-always contract.
    """
    p = urllib.parse.urlparse(url)
    try:
        port = p.port
    except ValueError:
        port = INVALID_PORT
    return (p.scheme, (p.hostname or "").lower(), port)


def is_loopback(host):
    """True for an address whose traffic never reaches a network interface."""
    if not host:
        return False
    host = host.lower()
    if host == "localhost" or host.endswith(".localhost"):
        return True
    try:
        return ipaddress.ip_address(host.strip("[]")).is_loopback
    except ValueError:  # a name; we are not about to resolve it to decide this
        return False


def transport_protects_token():
    """Whether this URL can carry a credential without publishing it.

    Deliberately not a check for a private IP range: an eavesdropper on the
    LAN is exactly the threat here, so 192.168.x.x earns no trust. Loopback is
    the only unencrypted case that is safe on its own merits.
    """
    scheme, host, _ = origin(opts.url)
    return scheme == "https" or is_loopback(host) or opts.allow_insecure_auth


def insecure_auth_active():
    """True when a token is riding a transport only the override permits.

    Reported to the widget rather than recomputed there, so the panel warns on
    what actually happened instead of on the setting: with no token, or over
    https, the flag is inert and there is nothing to warn about.
    """
    if opts is None or not token() or not opts.allow_insecure_auth:
        return False
    scheme, host, _ = origin(opts.url)
    return not (scheme == "https" or is_loopback(host))


class SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Keeps a redirect from walking the token off to another origin.

    urllib replays our Authorization header on every hop it follows, and an
    absolute Location carries the query string with it, so a site that has
    been taken over -- or just misconfigured -- could hand the token to a
    host the user never named. Only an http -> https upgrade of the same host
    is followed; any other origin change stops here with a message naming
    where it wanted to go.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        old, new = origin(req.full_url), origin(urllib.parse.urljoin(req.full_url, newurl))
        upgrade = (old[0] == "http" and new[0] == "https" and old[1] == new[1])
        if old != new and not upgrade:
            raise urllib.error.HTTPError(
                req.full_url, code,
                f"refusing redirect to a different site ({new[0]}://{new[1]}); "
                f"set `url` to the address you actually want",
                headers, fp)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


OPENER = urllib.request.build_opener(SafeRedirectHandler)


def get_json(path):
    """Fetch `path`, carrying the token if the transport is allowed to.

    The token goes in the query string because that is the only thing the
    endpoints this widget needs will accept -- see the module docstring. The
    protection against exposing it is transport_protects_token(), not the
    placement.
    """
    url = f"{opts.url}{path}"
    tok = token() if transport_protects_token() else None
    if tok:
        # Some paths already carry a query string, so the separator depends.
        url += ("&" if "?" in path else "?") + \
            f"token={urllib.parse.quote(tok, safe='')}"
    with OPENER.open(urllib.request.Request(url), timeout=opts.timeout) as r:
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
    ap.add_argument("--allow-insecure-auth", action="store_true",
                    help="send the token over plain http to a non-loopback host "
                         "(exposes it, and your readings, to the network)")
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

    scheme, host, port = origin(opts.url)
    if scheme not in ("http", "https"):
        fail("Bad Nightscout URL",
             f"`url` must start with https:// or http:// "
             f"(got {scheme + '://' if scheme else 'no scheme'}).",
             "⚠️ URL Invalid",
             "unconfigured")

    if not host or port is INVALID_PORT:
        fail("Bad Nightscout URL",
             "`url` is not a usable address. Expected something like "
             "https://mysite.example.com:1337.",
             "⚠️ URL Invalid",
             "unconfigured")

    # Checked before the first request, not at send time, so the failure names
    # the setting to change rather than surfacing as a 401 further down.
    if token() and not transport_protects_token():
        fail("Insecure Nightscout URL",
             f"The read-only token would go to {host} in clear text over plain "
             f"http, exposing it and your glucose data to anyone on the "
             f"network. Use an https:// URL, or -- only on a network you "
             f"trust -- set \"allowInsecureAuth\": true on this widget's entry "
             f"in ~/.config/omarchy/shell.json. A site running "
             f"AUTH_DEFAULT_ROLES=readable needs no token: removing "
             f"{opts.token_file} polls it anonymously.",
             "⚠️ Insecure",
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
        "insecureAuth": insecure_auth_active(),
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
