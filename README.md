# Salati — صلاتي

Islamic prayer times for the Omarchy bar. The bar shows a single crescent-moon
icon; clicking it opens a panel with a live countdown to the next prayer and
the full day schedule.

- **Icon-only bar pill.** No text, no countdown in the bar — just the moon
  glyph. Hovering shows the localized “Prayer times” tooltip; a left click
  opens the panel.
- **Hero countdown.** Large `H:MM:SS` digits count down to the next prayer.
  Hours are not zero-padded; minutes and seconds are. A caption beneath the
  digits names the prayer (“until Maghrib”, “متبقّي على المغرب”).
- **Six-row schedule.** Fajr, Sunrise, Dhuhr, Asr, Maghrib, Isha. Sunrise is
  informational only. Passed rows are dimmed; the next prayer is highlighted.
  After Isha the countdown continues against tomorrow’s Fajr.
- **Arabic and English UI**, following the shell language live.

## Settings

| Key | Values | Meaning |
| --- | --- | --- |
| `locationMode` | `auto` (default), `manual`, `offline` | How the location is obtained. |
| `latitude` | decimal degrees | Used in `manual` and `offline`, and as a fallback in `auto`. |
| `longitude` | decimal degrees | Same as latitude. |
| `calculationMethod` | `umm_al_qura` (default), `muslim_world_league`, `isna`, `egypt`, `karachi` | Passed to AlAdhan as method 4 / 3 / 2 / 5 / 1. |
| `madhab` | `standard` (default), `hanafi` | Asr juristic method; passed to AlAdhan as school 0 / 1. |

### Location modes

- **`auto`** — the panel asks `https://geo.omarchy.org/` where this network is,
  then requests AlAdhan with those coordinates. IP geolocation is city-level
  (roughly ±25 km), so times can differ by a minute or two from a precise
  address. The service's place *name* is ignored; only the decimal coordinates
  are used.
- **`manual`** — no IP geolocation request is ever made. AlAdhan is queried
  directly with the configured latitude and longitude.
- **`offline`** — no network calls at all. Times are calculated locally by the
  bundled PrayTimes engine from the configured coordinates.

If the latitude or longitude is missing or outside its valid range, Salati
falls back to the built-in Riyadh defaults (`24.7136, 46.6753`) rather than
showing a blank panel.

## Network use and disclosure

The panel footer always states where the displayed times came from:

- `Times: AlAdhan.com · location auto-detected`
- `Times: AlAdhan.com · manual coordinates`
- `Offline · calculated locally`

Network requests happen **only when the panel is opened** and its data is
missing, from a previous day, or older than 30 minutes:

1. `https://geo.omarchy.org/` — Omarchy’s own first-party location service
   (the one its weather widget uses). If it fails, `https://ipwho.is/` is tried
   once as a fallback.
2. `https://api.aladhan.com/v1/timings/<dd-MM-yyyy>?latitude=…&longitude=…&method=…&school=…`
   — today’s times and, in the same session, tomorrow’s Fajr for the
   after-Isha countdown.

At most three `curl` invocations are made per local day (one geolocation
lookup plus today’s and tomorrow’s timings). Nothing is fetched while the
panel is closed — the widget loads hidden at shell startup but makes no
request until it is first opened.

`manual` mode sends only your configured coordinates to AlAdhan. `offline`
mode makes zero network calls.

All responses are size-limited, parsed with `JSON.parse` in a `try` block, and
validated before display: the Gregorian date echoed by AlAdhan must match the
date requested, and every time must match `HH:MM` with hours 00–23 and minutes
00–59. Only those validated strings reach the UI. Nothing downloaded is ever
executed, written to disk, or interpolated into a shell command.

## Fallback behaviour

If a network request fails in `auto` or `manual` mode, Salati quietly falls
back to the local PrayTimes calculation (using the last detected coordinates
this session, then the configured coordinates, then the Riyadh defaults) and
the footer switches to `Offline · calculated locally`. No error dialog, no
blank values, and no retry loop: one attempt per panel open, plus one at
midnight if the panel is left open.

## Umm al-Qura note

The Umm al-Qura method (the default) computes Isha as **90 minutes after
Maghrib** rather than from a solar angle. This is the method’s published
definition and is reproduced by both AlAdhan and the bundled engine.

## License and attributions

MIT.

- Prayer-time engine (`PrayTimes.js`), used for `offline` mode and network
  fallback: PrayTimes v3.2, © Hamid Zarrabi-Zadeh, MIT —
  <https://praytimes.org>.
- Network timings: [AlAdhan.com](https://api.aladhan.com) public API.
- Network geolocation: `geo.omarchy.org` (Omarchy first-party), with
  `ipwho.is` as a fallback.
