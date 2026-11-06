.pragma library

// praytimes.js - Prayer Times Calculator (v3.2)
// Copyright (c) 2007-2025 Hamid Zarrabi-Zadeh
// Source: https://praytimes.org
// License: MIT
//
// Ported to the Qt QML JavaScript engine for Salati. The astronomical
// formulas, method angles, and high-latitude guard below are PrayTime v3.2's.
// The v3.2 user interface (timezones, Intl formatting, tuning) is replaced by
// one pure function that returns civil-clock minute values for a local day,
// because QML's JS engine has no Intl and the plugin must stay offline.
//
// Times returned by compute() are minutes after local midnight on the date
// passed in. The local UTC offset comes from the Date itself (i.e. the
// system's own timezone at that date), not from a timezone database name.

var METHODS = {
  umm_al_qura:          { fajr: 18.5, isha: null, ishaMinutes: 90 },
  muslim_world_league:  { fajr: 18,   isha: 17 },
  isna:                 { fajr: 15,   isha: 15 },
  egypt:                { fajr: 19.5, isha: 17.5 },
  karachi:              { fajr: 18,   isha: 18 }
};

var HORIZON = 0.833; // standard sunrise/sunset depression, degrees

// ---- Degree-based trigonometry (PrayTime v3.2) -------------------------

function dtr(d) { return d * Math.PI / 180 }
function rtd(r) { return r * 180 / Math.PI }
function sin(d) { return Math.sin(dtr(d)) }
function cos(d) { return Math.cos(dtr(d)) }
function tan(d) { return Math.tan(dtr(d)) }
function arcsin(x) { return rtd(Math.asin(x)) }
function arccos(x) { return rtd(Math.acos(x)) }
function arccot(x) { return rtd(Math.atan(1 / x)) }
function arctan2(y, x) { return rtd(Math.atan2(y, x)) }

// Positive modulo.
function mod(a, b) { return ((a % b) + b) % b }

// ---- Solar position (PrayTime v3.2) ------------------------------------

// dayUtcMs is the UTC midnight of the civil day, timeHours the current
// estimate in hours, lng the longitude in degrees (east positive).
function sunPosition(dayUtcMs, timeHours, lng) {
  var D = dayUtcMs / 86400000 - 10957.5 + timeHours / 24 - lng / 360;

  var g = mod(357.529 + 0.98560028 * D, 360);
  var q = mod(280.459 + 0.98564736 * D, 360);
  var L = mod(q + 1.915 * sin(g) + 0.020 * sin(2 * g), 360);
  var e = 23.439 - 0.00000036 * D;
  var RA = mod(arctan2(cos(e) * sin(L), cos(L)) / 15, 24);

  return {
    declination: arcsin(sin(e) * sin(L)),
    equation: q / 15 - RA
  };
}

function midDay(dayUtcMs, timeHours, lng) {
  var eqt = sunPosition(dayUtcMs, timeHours, lng).equation;
  return mod(12 - eqt, 24);
}

// Time the sun reaches `angle` below the horizon. direction -1 rises,
// +1 sets. Returns NaN when the sun never reaches the angle that day.
function angleTime(dayUtcMs, angle, timeHours, lng, lat, direction) {
  var decl = sunPosition(dayUtcMs, timeHours, lng).declination;
  var numerator = -sin(angle) - sin(lat) * sin(decl);
  var denominator = cos(lat) * cos(decl);
  var ratio = numerator / denominator;
  if (ratio < -1 || ratio > 1) return NaN;
  var diff = arccos(ratio) / 15;
  if (isNaN(diff)) return NaN;
  return midDay(dayUtcMs, timeHours, lng) + diff * direction;
}

// Asr: cot(alpha) = shadow + tan(|lat - decl|); shadow 1 standard, 2 Hanafi.
function asrAngle(dayUtcMs, shadow, lng, lat, timeHours) {
  var decl = sunPosition(dayUtcMs, timeHours, lng).declination;
  return -arccot(shadow + tan(Math.abs(lat - decl)));
}

// ---- Higher-latitude guard (PrayTime v3.2, NightMiddle rule) -----------

// Keep an angle-based event within `portion` hours of its base in the
// direction it belongs: Fajr before sunrise (direction -1), Isha after
// sunset (direction +1). Applied on every run, not only when the angle
// calculation produced NaN, so the six times stay ordered at high latitudes.
function clampEvent(time, base, direction, portion) {
  if (!isFinite(portion) || portion <= 0) return time;
  var diff = (time - base) * direction;
  if (!isFinite(time) || diff > portion) return base + portion * direction;
  return time;
}

// ---- Public calculation ------------------------------------------------

function emptyTimes() {
  return {
    fajr: NaN, sunrise: NaN, dhuhr: NaN,
    asr: NaN, maghrib: NaN, isha: NaN,
    sunset: NaN, valid: false
  };
}

// eventHours is in "solar" hours; subtract the longitude to reach UTC, then
// add the civil day's UTC offset (east positive).
function toLocalMinutes(eventHours, lng, offsetMinutes) {
  if (!isFinite(eventHours)) return NaN;
  // Event hours are measured from UTC midnight; longitude is already part
  // of the solar-position calculation and must not be subtracted again.
  return eventHours * 60 + offsetMinutes;
}

// Compute the six display times for the local civil day containing `date`.
// `lat`/`lng` are decimal degrees, `methodKey` one of METHODS, `madhabKey`
// "standard" or "hanafi".
function compute(date, lat, lng, methodKey, madhabKey) {
  var latN = Number(lat);
  var lngN = Number(lng);
  if (!isFinite(latN) || !isFinite(lngN) || latN < -90 || latN > 90 || lngN < -180 || lngN > 180)
    return emptyTimes();

  var method = METHODS[methodKey] || METHODS.umm_al_qura;
  var shadow = madhabKey === "hanafi" ? 2 : 1;

  var y = date.getFullYear();
  var mo = date.getMonth();
  var d = date.getDate();
  var dayUtc = Date.UTC(y, mo, d);
  var offsetMinutes = -new Date(y, mo, d).getTimezoneOffset();

  var fajr = angleTime(dayUtc, method.fajr, 5, lngN, latN, -1);
  var sunrise = angleTime(dayUtc, HORIZON, 6, lngN, latN, -1);
  var dhuhr = midDay(dayUtc, 12, lngN);
  var asr = angleTime(dayUtc, asrAngle(dayUtc, shadow, lngN, latN, 13), 13, lngN, latN, 1);
  var sunset = angleTime(dayUtc, HORIZON, 18, lngN, latN, 1);
  var maghrib = sunset;
  var isha = method.isha === null
    ? maghrib + method.ishaMinutes / 60
    : angleTime(dayUtc, method.isha, 18, lngN, latN, 1);

  // Night length from today's sunset to tomorrow's sunrise.
  var tomorrowUtc = Date.UTC(y, mo, d + 1);
  var sunriseTomorrow = angleTime(tomorrowUtc, HORIZON, 6, lngN, latN, -1);
  var night = 24 + sunriseTomorrow - sunset;
  if (isFinite(night) && night > 0) {
    var portion = Math.abs(latN) > 48 ? night / 7 : night / 2;
    fajr = clampEvent(fajr, sunrise, -1, portion);
    // Umm al-Qura's Isha is minute-based and needs no angular clamp.
    if (method.isha !== null) isha = clampEvent(isha, sunset, 1, portion);
  }

  var out = {
    fajr: toLocalMinutes(fajr, lngN, offsetMinutes),
    sunrise: toLocalMinutes(sunrise, lngN, offsetMinutes),
    dhuhr: toLocalMinutes(dhuhr, lngN, offsetMinutes),
    asr: toLocalMinutes(asr, lngN, offsetMinutes),
    maghrib: toLocalMinutes(maghrib, lngN, offsetMinutes),
    isha: toLocalMinutes(isha, lngN, offsetMinutes),
    sunset: toLocalMinutes(sunset, lngN, offsetMinutes)
  };
  out.valid = isFinite(out.fajr) && isFinite(out.sunrise) && isFinite(out.dhuhr)
    && isFinite(out.asr) && isFinite(out.maghrib) && isFinite(out.isha);
  return out;
}

function methodKeys() {
  return ["umm_al_qura", "muslim_world_league", "isna", "egypt", "karachi"];
}
