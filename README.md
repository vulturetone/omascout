# Omascout 

Current blood glucose in the bar, coloured using your own Nightscout server's
thresholds, with a popup showing the reading's age and, where it can be
derived, how much sensor life is left.

## images

### Top Bar and Panel
![preview](preview.png)

### Demo mode
![demo](demo.png)



## Install

```bash
omarchy plugin add https://github.com/vulturetone/omascout.git --enable --yes
```

Then set at least the site URL on the widget's entry in
`~/.config/omarchy/shell.json`:

```json
{ 
  "id": "vulturetone.omascout", 
  "url": "https://mysite.example.com:1337", 
  "sensorDays": 15 
}
```

Without a `url` the pill shows an error.

## Settings

Every setting is inline on the widget's `shell.json` entry. There is no
second config file.

| Key | Default | What it does |
|---|---|---|
| `url` | *(none)* | Base URL of your Nightscout site. **Required.** |
| `intervalSec` | `60` | Poll interval. Most uploaders post about once a minute; faster only adds load. |
| `tokenFile` | `~/.config/nightscout-token` | File holding a read-only access token. Optional; see below. |
| `sensorDays` | `0` | Sensor wear time in days. `0` turns sensor tracking off entirely. |
| `warmupMins` | `60` | Warmup before a sensor's first reading, backdated to estimate activation. |
| `warnHours` | `24` | Outline the pill once this little wear time remains. |
| `staleMins` | `5` | Minutes without a reading before the pill greys out. |
| `timeoutSec` | `4` | HTTP timeout. |

Glucose colours are a traffic light, so they're fixed rather than theme
roles: a reading has to mean the same thing under every theme. Override any
of them if they clash with yours.


## Interactions

| | |
|---|---|
| left click | popup with delta, reading age, and sensor life |
| right click | open your Nightscout site |
| middle click | refresh |

Also on IPC: `omarchy-shell vulturetone.omascout refresh|open|close|show|hide|toggle`.

The popup's **Demo** button cycles the bar and panel through every state on a
one-second loop: each glucose class, the sensor warnings, and the error
states. Handy for checking a custom palette without waiting for real glucose
to go there. Polling pauses while it runs, and closing the popup ends it, so
a fake reading can't be left sitting on the bar.

## Thresholds and units

Thresholds are read from your site's own `/api/v1/status.json`, so changing
them in Nightscout changes every client at once. Nightscout publishes them in
mg/dL and the properties endpoint returns raw mgdl alongside the
display-scaled value, so classification happens in mg/dL and the pill shows
whatever unit your site displays. If the site has never been reachable,
Nightscout's own defaults are used. Units come from the server for the same
reason, so there's no unit setting here.

Colours aren't themed, but you can override them if they clash. I'll look into making it pick up themes from Omarchy in future. 

## Authentication

A site running `AUTH_DEFAULT_ROLES=readable` needs no credential and works
with no `tokenFile` at all. When the file exists its contents are sent as a
read-only token, so locking a site down to `denied` later needs no change
here.

Keep that file outside any directory your dotfile manager syncs. The default
sits in `~/.config/` rather than next to this plugin because
`~/.config/omarchy/` is the sort of directory people push to a remote.

## Sensor expiry

Not every uploader reports it. Juggluco, for one, forwards only the sensor
serial (in each entry's `device` field) and posts no Sensor Start/Change
treatments, so there is nothing to read. Where `sensorDays` is set, expiry
is *derived* instead: the oldest reading carrying a given serial is that
sensor's first post-warmup reading, which dates the activation. Uploaders
that backfill history on connect make this hold for sensors that predate
the Nightscout install.

That scan is expensive, so it's cached per serial and runs once per sensor
rather than once per poll. Thresholds are cached for 30 minutes.

Set `sensorDays` to `0` where the derivation does not apply, such as a site
whose uploader posts real sensor treatments, or a sensor with no fixed wear
time. The whole sensor section then disappears from the popup.

Wear times that I am aware of:  Libre 2: 14, Libre 2 Plus: 15

## Design notes

The sensor warning is additive: an outline around the pill and a suffix on
its text, not a colour change. The glucose class keeps the text colour, so an
urgent low can't be masked by a sensor that happens to be expiring at the
same time.

On a vertical bar the pill drops the trend arrow and the expiry suffix and
shrinks the number to fit the slot.

The reading is fetched by `scripts/nightscout.py`, which prints one JSON
object and is runnable by hand:

```bash
./scripts/nightscout.py --url https://mysite.example.com --sensor-days 15
```

Every knob the widget has is a flag on that script.
