#!/usr/bin/env python3
"""Genera un dashboard HTML autocontenido con los datos de la Fitbit Air (Google Health API).

Reutiliza la autenticación y la lectura de probe.py (requiere haber hecho `probe.py auth`).
El HTML resultante contiene tus datos de salud: está ignorado por git, no lo subas.

Uso:
  set -a; source ~/.fitbit-probe.env; set +a
  python3 dashboard.py [--days 14] [-o dashboard.html]
  python3 dashboard.py --from-raw raw.json      # reutiliza un volcado previo sin llamar a la API
  python3 dashboard.py --save-raw raw.json      # además guarda el volcado crudo
"""
import argparse
import json
import re
import sys
import time
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import probe  # noqa: E402

LABELS = {
    "steps": "Pasos", "distance": "Distancia", "total-calories": "Calorías totales (rollup)",
    "active-minutes": "Minutos activos", "active-zone-minutes": "Minutos en zona activa",
    "sedentary-period": "Periodos sedentarios", "swim-lengths-data": "Natación (brazadas)",
    "heart-rate": "Frecuencia cardíaca", "heart-rate-variability": "HRV (muestras)",
    "oxygen-saturation": "SpO₂ (muestras)", "respiratory-rate-sleep-summary": "Resp. en sueño (resumen)",
    "run-vo2-max": "VO₂ máx. (carrera)", "vo2-max": "VO₂ máx. (muestras)",
    "daily-resting-heart-rate": "FC en reposo (diaria)", "daily-heart-rate-variability": "HRV (diaria)",
    "daily-oxygen-saturation": "SpO₂ (diaria)", "daily-respiratory-rate": "Frec. respiratoria (diaria)",
    "daily-sleep-temperature-derivations": "Temperatura nocturna", "daily-vo2-max": "VO₂ máx. (diario)",
    "exercise": "Ejercicios", "sleep": "Sueño",
}


# ---------- lectura ----------
def fetch(days):
    out = {}
    for dt, kind in probe.AIR_TYPES.items():
        if dt in probe.ROLLUP_ONLY:
            continue
        params = {"pageSize": probe.PAGE_SIZE_CAP.get(dt, 10000 if kind in ("sample", "interval") else 1440)}
        flt = probe.range_filter(dt, days)
        if flt:
            params["filter"] = flt
        status, err, pages, pts = probe.fetch_all(dt, params, 60)
        if err is not None:
            print(f"  {dt}: HTTP {status} {str(err)[:120]}", file=sys.stderr)
        print(f"  {dt:38} HTTP {status} pág={pages} pts={len(pts)}", file=sys.stderr, flush=True)
        out[dt] = {"kind": kind, "http": status, "points": pts}
    end = date.today() + timedelta(days=1)
    start = end - timedelta(days=min(days, 14))
    status, resp = probe.api_post("users/me/dataTypes/total-calories/dataPoints:dailyRollUp",
                                  {"range": {"start": probe.civil(start), "end": probe.civil(end)},
                                   "windowSizeDays": 1})
    pts = resp.get("rollupDataPoints", []) if isinstance(resp, dict) else []
    print(f"  {'total-calories (rollup)':38} HTTP {status} pts={len(pts)}", file=sys.stderr)
    out["total-calories"] = {"kind": "rollup", "http": status, "points": pts}
    return out


# ---------- utilidades de tiempo ----------
def parse(iso):
    m = re.match(r"(.*?)(\.\d+)?(Z|[+-]\d\d:\d\d)$", iso)
    base, frac, tz = m.groups()
    frac = (frac or "")[:7]
    return datetime.fromisoformat(base + frac + ("+00:00" if tz == "Z" else tz))


def off(s):
    return int(s.rstrip("s")) if s else 0


def loc(iso, offs):
    return (parse(iso) + timedelta(seconds=off(offs))).replace(tzinfo=None)


def cdate(c):
    d = c["date"]
    return f'{d["year"]:04d}-{d["month"]:02d}-{d["day"]:02d}'


def cdt(c):
    d, t = c["date"], c.get("time", {})
    return datetime(d["year"], d["month"], d["day"], t.get("hours", 0), t.get("minutes", 0), t.get("seconds", 0))


def camel(dt):
    p = dt.split("-")
    return p[0] + "".join(x.title() for x in p[1:])


def body(pt, dt):
    return pt.get(camel(dt), {})


def last_ts(dt, pts):
    """Instante UTC (aware) o fecha (str) del punto más reciente, y el primero."""
    vals = []
    for pt in pts:
        o = body(pt, dt)
        if "interval" in o and "startTime" in o["interval"]:
            vals.append(parse(o["interval"]["startTime"]))
        elif "sampleTime" in o:
            vals.append(parse(o["sampleTime"]["physicalTime"]))
        elif "date" in o:
            vals.append(cdate(o))
        elif "civilStartTime" in pt:
            vals.append(cdate(pt["civilStartTime"]))
    return (min(vals), max(vals)) if vals else (None, None)


# ---------- agregación ----------
def source_name(pt):
    ds = pt.get("dataSource") or {}
    if ds.get("platform") == "FITBIT":
        return (ds.get("device") or {}).get("displayName") or "Fitbit (derivado)"
    if ds.get("platform") == "HEALTH_KIT":
        return "Apple Health (HealthKit)"
    return ds.get("platform") or "(sin fuente)"


def is_air(pt):
    """La API mezcla fuentes en la misma lista: Fitbit/Air y p. ej. Apple Health. Los rollups no traen fuente."""
    return "dataSource" not in pt or (pt["dataSource"] or {}).get("platform") == "FITBIT"


def aggregate(raw, days_n, source="air"):
    now = datetime.now()
    days = [(date.today() - timedelta(days=i)).isoformat() for i in range(days_n - 1, -1, -1)]
    idx = {d: i for i, d in enumerate(days)}

    def series():
        return [None] * len(days)

    def add(arr, d, v):
        i = idx.get(d)
        if i is not None and v is not None:
            arr[i] = (arr[i] or 0) + v

    def put(arr, d, v):
        i = idx.get(d)
        if i is not None and v is not None:
            arr[i] = v

    keep = is_air if source == "air" else (lambda _p: True)
    pts = lambda dt: [p for p in raw.get(dt, {}).get("points", []) if keep(p)]
    D = {"days": days, "source": source}

    # actividad por minuto
    steps, dist, swim, sed = series(), series(), series(), series()
    for p in pts("steps"):
        o = p["steps"]; add(steps, cdate(o["interval"]["civilStartTime"]), int(o["count"]))
    for p in pts("distance"):
        o = p["distance"]; add(dist, cdate(o["interval"]["civilStartTime"]), int(o["millimeters"]) / 1e6)
    for p in pts("swim-lengths-data"):
        o = p["swimLengthsData"]; add(swim, cdate(o["interval"]["civilStartTime"]), int(o.get("strokeCount", 0)))
    for p in pts("sedentary-period"):
        o = p["sedentaryPeriod"]["interval"]
        add(sed, cdate(o["civilStartTime"]), (parse(o["endTime"]) - parse(o["startTime"])).total_seconds() / 60)
    levels = defaultdict(series)
    for p in pts("active-minutes"):
        o = p["activeMinutes"]; d = cdate(o["interval"]["civilStartTime"])
        for l in o.get("activeMinutesByActivityLevel", []):
            add(levels[l["activityLevel"]], d, int(l["activeMinutes"]))
    zones = defaultdict(series)
    for p in pts("active-zone-minutes"):
        o = p["activeZoneMinutes"]; add(zones[o["heartRateZone"]], cdate(o["interval"]["civilStartTime"]), int(o["activeZoneMinutes"]))
    kcal = series()
    for p in pts("total-calories"):
        put(kcal, cdate(p["civilStartTime"]), p["totalCalories"]["kcalSum"])
    D.update(steps=steps, distKm=dist, swim=swim, sedMin=sed, kcal=kcal,
             levels=dict(levels), zones=dict(zones))

    # frecuencia cardíaca
    hr_by_day = defaultdict(list)
    samples = []
    for p in pts("heart-rate"):
        o = p["heartRate"]; t = loc(o["sampleTime"]["physicalTime"], o["sampleTime"].get("utcOffset"))
        v = int(o["beatsPerMinute"])
        hr_by_day[t.date().isoformat()].append(v); samples.append((t, v))
    D["hrMin"], D["hrAvg"], D["hrMax"] = series(), series(), series()
    for d, vs in hr_by_day.items():
        put(D["hrMin"], d, min(vs)); put(D["hrMax"], d, max(vs)); put(D["hrAvg"], d, round(sum(vs) / len(vs), 1))
    hr24 = []
    if samples:
        tmax = max(t for t, _ in samples)
        t0 = (tmax - timedelta(hours=24)).replace(minute=(tmax.minute // 10) * 10, second=0, microsecond=0)
        buckets = defaultdict(list)
        for t, v in samples:
            if t >= t0:
                b = t.replace(minute=(t.minute // 10) * 10, second=0, microsecond=0)
                buckets[b].append(v)
        b, end = t0, tmax
        while b <= end:
            vs = buckets.get(b)
            hr24.append([b.strftime("%d %H:%M"), round(sum(vs) / len(vs), 1) if vs else None,
                         min(vs) if vs else None, max(vs) if vs else None, len(vs) if vs else 0])
            b += timedelta(minutes=10)
    D["hr24"] = hr24

    # pasos por hora (últimas 24 h)
    hourly = defaultdict(int)
    for p in pts("steps"):
        o = p["steps"]["interval"]; hourly[loc(o["startTime"], o.get("startUtcOffset")).replace(minute=0, second=0, microsecond=0)] += int(p["steps"]["count"])
    if hourly:
        tmax = max(hourly); h = tmax - timedelta(hours=23)
        D["steps24"] = [[(h + timedelta(hours=i)).strftime("%d %H:00"), hourly.get(h + timedelta(hours=i), 0)] for i in range(24)]
    else:
        D["steps24"] = []

    # diarios
    def daily(dt, fields):
        res = {k: series() for k in fields}
        for p in pts(dt):
            o = p[camel(dt)]; d = cdate(o)
            for k, src in fields.items():
                v = o.get(src)
                put(res[k], d, float(v) if v is not None else None)
        return res

    D["rhr"] = daily("daily-resting-heart-rate", {"v": "beatsPerMinute"})["v"]
    h = daily("daily-heart-rate-variability", {"avg": "averageHeartRateVariabilityMilliseconds",
                                                "deep": "deepSleepRootMeanSquareOfSuccessiveDifferencesMilliseconds",
                                                "nrem": "nonRemHeartRateBeatsPerMinute", "entropy": "entropy"})
    D["hrv"] = h
    D["spo2"] = daily("daily-oxygen-saturation", {"avg": "averagePercentage", "lo": "lowerBoundPercentage", "hi": "upperBoundPercentage"})
    D["resp"] = daily("daily-respiratory-rate", {"v": "breathsPerMinute"})["v"]
    D["temp"] = daily("daily-sleep-temperature-derivations", {"night": "nightlyTemperatureCelsius",
                                                              "base": "baselineTemperatureCelsius",
                                                              "sd": "relativeNightlyStddev30dCelsius"})
    D["vo2"] = daily("daily-vo2-max", {"v": "vo2Max"})["v"]
    D["vo2Level"] = None
    for p in sorted(pts("daily-vo2-max"), key=lambda p: cdate(p["dailyVo2Max"])):
        D["vo2Level"] = p["dailyVo2Max"].get("cardioFitnessLevel")

    # sueño
    nights, latest = [], None
    for p in pts("sleep"):
        s = p["sleep"]; iv = s["interval"]
        st, en = loc(iv["startTime"], iv.get("startUtcOffset")), loc(iv["endTime"], iv.get("endUtcOffset"))
        summ = s.get("summary", {})
        stages = {x["type"]: int(x["minutes"]) for x in summ.get("stagesSummary", [])}
        rec = {"date": en.date().isoformat(), "start": st.strftime("%d %H:%M"), "end": en.strftime("%d %H:%M"),
               "main": bool(s.get("metadata", {}).get("mainSleep")), "type": s.get("type"),
               "inBed": int(summ.get("minutesInSleepPeriod", 0)), "asleep": int(summ.get("minutesAsleep", 0)),
               "awake": int(summ.get("minutesAwake", 0)), "stages": stages,
               "awakenings": len(s.get("shortAwakenings", []))}
        nights.append(rec)
        if rec["main"] and (latest is None or en > latest[0]):
            latest = (en, st, s)
    nights.sort(key=lambda r: (r["date"], r["start"]))
    D["nights"] = nights
    D["hypno"], D["night_window"] = [], None
    if latest:
        en, st, s = latest
        D["night_window"] = [st.strftime("%d %H:%M"), en.strftime("%d %H:%M")]
        for x in s.get("stages", []):
            a, b = loc(x["startTime"], x.get("startUtcOffset")), loc(x["endTime"], x.get("endUtcOffset"))
            D["hypno"].append([(a - st).total_seconds() / 60, (b - st).total_seconds() / 60, x["type"]])
        D["hypno_total"] = (en - st).total_seconds() / 60
        D["hypno_start"] = st.strftime("%H:%M")

        def within(dt, key, field):
            res = []
            for p in pts(dt):
                o = p[key]; t = loc(o["sampleTime"]["physicalTime"], o["sampleTime"].get("utcOffset"))
                if st <= t <= en and o.get(field) is not None:
                    res.append((t, o[field]))
            res.sort()
            return [[t.strftime("%H:%M"), v] for t, v in res]

        D["night_hrv"] = within("heart-rate-variability", "heartRateVariability", "rootMeanSquareOfSuccessiveDifferencesMilliseconds")
        D["night_spo2"] = within("oxygen-saturation", "oxygenSaturation", "percentage")
        hrn = [(t, v) for t, v in samples if st <= t <= en]
        D["night_hr"] = [[t.strftime("%H:%M"), v] for t, v in sorted(hrn)][::max(1, len(hrn) // 120)]
    else:
        D["night_hrv"], D["night_spo2"], D["night_hr"] = [], [], []

    # respiración en sueño por fase
    rs = []
    for p in pts("respiratory-rate-sleep-summary"):
        o = p["respiratoryRateSleepSummary"]
        rs.append({"date": loc(o["sampleTime"]["physicalTime"], o["sampleTime"].get("utcOffset")).date().isoformat(),
                   **{k: (o.get(f"{k}SleepStats") or {}).get("breathsPerMinute") for k in ("deep", "light", "rem", "full")}})
    rs.sort(key=lambda r: r["date"])
    D["respStages"] = rs

    # ejercicios
    ex = []
    for p in pts("exercise"):
        e = p["exercise"]; iv = e["interval"]; m = e.get("metricsSummary", {})
        st, en = loc(iv["startTime"], iv.get("startUtcOffset")), loc(iv["endTime"], iv.get("endUtcOffset"))
        z = m.get("heartRateZoneDurations", {})
        ex.append({"name": e.get("displayName") or e.get("exerciseType"), "type": e.get("exerciseType"),
                   "start": st.strftime("%Y-%m-%d %H:%M"), "min": round((en - st).total_seconds() / 60),
                   "kcal": m.get("caloriesKcal"), "km": (m.get("distanceMillimeters") or 0) / 1e6,
                   "steps": int(m["steps"]) if m.get("steps") else None,
                   "hr": int(m["averageHeartRateBeatsPerMinute"]) if m.get("averageHeartRateBeatsPerMinute") else None,
                   "pace": (m["averagePaceSecondsPerMeter"] * 1000 / 60) if m.get("averagePaceSecondsPerMeter") else None,
                   "zones": {k.replace("Time", ""): int(str(v).rstrip("s")) // 60 for k, v in z.items()}})
    ex.sort(key=lambda r: r["start"], reverse=True)
    D["exercise"] = ex

    # cobertura y frescura
    cov = []
    gen = datetime.now(timezone.utc)
    for dt in probe.AIR_TYPES:
        r = raw.get(dt, {})
        mine = pts(dt)
        first, last = last_ts(dt, mine) if mine else (None, None)
        age = None
        if isinstance(last, datetime):
            age = round((gen - last).total_seconds() / 60)
        cov.append({"type": dt, "label": LABELS.get(dt, dt), "kind": r.get("kind"), "http": r.get("http"),
                    "n": len(mine), "other": len(r.get("points", [])) - len(mine),
                    "first": first.isoformat() if isinstance(first, datetime) else first,
                    "last": last.isoformat() if isinstance(last, datetime) else last,
                    "ageMin": age})
    D["coverage"] = cov
    devs = defaultdict(int)
    for v in raw.values():
        for p in v["points"]:
            devs[source_name(p) if "dataSource" in p else "Rollup (sin fuente)"] += 1
    D["devices"] = dict(devs)
    D["generated"] = now.strftime("%Y-%m-%d %H:%M")
    D["windowDays"] = days_n
    return D


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("-o", "--output", default=str(Path(__file__).with_name("dashboard.html")))
    ap.add_argument("--source", choices=["air", "all"], default="air",
                    help="air (por defecto): solo datos de Fitbit/Air; all: también Apple Health y otras fuentes")
    ap.add_argument("--from-raw")
    ap.add_argument("--save-raw")
    a = ap.parse_args()
    t0 = time.time()
    if a.from_raw:
        raw = json.loads(Path(a.from_raw).read_text())
    else:
        print(f"Pidiendo {a.days} días a Google Health API…", file=sys.stderr)
        raw = fetch(a.days)
    if a.save_raw:
        Path(a.save_raw).write_text(json.dumps(raw))
    data = aggregate(raw, a.days, a.source)
    tpl = Path(__file__).with_name("dashboard_template.html").read_text()
    html = tpl.replace("/*__DATA__*/null", json.dumps(data, ensure_ascii=False))
    Path(a.output).write_text(html)
    print(f"OK -> {a.output} ({len(html) / 1024:.0f} KB, {time.time() - t0:.0f}s)", file=sys.stderr)


if __name__ == "__main__":
    main()
