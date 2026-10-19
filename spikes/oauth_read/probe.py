#!/usr/bin/env python3
"""Spike: OAuth 2.0 (code + PKCE, loopback) y lectura de datos de Google Health API.

Solo librería estándar. NO es el backend: es una sonda para responder
"¿me deja Google autorizar y leer mis datos reales?".

Variables de entorno:
  GH_CLIENT_ID, GH_CLIENT_SECRET   cliente OAuth de Google Cloud
  GH_API_BASE   (opcional) por defecto https://health.googleapis.com/v4
  GH_TOKEN_FILE (opcional) por defecto ./probe.token.json (ignorado por git)

Uso:
  python3 probe.py auth
  python3 probe.py read <dataType> [--days N] [--param k=v ...] [--page-size N] [--max-pages N] [--source air|all]
  python3 probe.py matrix [--days N] [--source air|all]
  python3 probe.py today                 # pasos/distancia de hoy (hora local) por fuente
  python3 probe.py rollup [total-calories] [--days N]   # POST dailyRollUp
  python3 probe.py raw <ruta>            # GET libre, p. ej. users/me/dataTypes

Host, ruta, nombres de dataType, filtro de rango y escopes verificados contra la documentación
oficial el 2026-10-08 (ver docs/FEASIBILITY.md). Aún NO se ha ejecutado contra Google: la sintaxis
exacta de `{type}.date` (daily) y los tipos Session están por confirmar con la primera respuesta real.
"""
import argparse
import base64
import hashlib
import http.server
import json
import os
import secrets
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from datetime import datetime, timedelta, timezone
from pathlib import Path

AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
SCOPE_PREFIX = "https://www.googleapis.com/auth/googlehealth."
SCOPES = [
    SCOPE_PREFIX + "activity_and_fitness.readonly",
    SCOPE_PREFIX + "health_metrics_and_measurements.readonly",
    SCOPE_PREFIX + "sleep.readonly",
]
REDIRECT_PORT = 8765
REDIRECT_URI = f"http://127.0.0.1:{REDIRECT_PORT}/callback"

API_BASE = os.environ.get("GH_API_BASE", "https://health.googleapis.com/v4").rstrip("/")
TOKEN_FILE = Path(os.environ.get("GH_TOKEN_FILE", Path(__file__).with_name("probe.token.json")))

# Tipos que la matriz de compatibilidad oficial lista para Fitbit Air (deviceId "air"), con su
# tipo de registro (decide el campo del filtro). Fuente: /health/data-types/device-compatibility
AIR_TYPES = {
    "steps": "interval", "distance": "interval", "total-calories": "interval",
    "active-minutes": "interval", "active-zone-minutes": "interval",
    "sedentary-period": "interval", "swim-lengths-data": "interval",
    "heart-rate": "sample", "heart-rate-variability": "sample", "oxygen-saturation": "sample",
    "respiratory-rate-sleep-summary": "sample", "run-vo2-max": "sample", "vo2-max": "sample",
    "daily-resting-heart-rate": "daily", "daily-heart-rate-variability": "daily",
    "daily-oxygen-saturation": "daily", "daily-respiratory-rate": "daily",
    "daily-sleep-temperature-derivations": "daily", "daily-vo2-max": "daily",
    "exercise": "exercise", "sleep": "sleep",
    # food-measurement-unit / nutrition-log: scope nutrition, fuera de nuestros 3 scopes
}
ROLLUP_ONLY = {"total-calories"}  # verificado: list devuelve 400, solo rollup/dailyRollup
CANDIDATE_TYPES = [t for t in AIR_TYPES if t not in ROLLUP_ONLY]
PAGE_SIZE_CAP = {"exercise": 25, "sleep": 25}  # default y máximo según la referencia


def source_name(pt):
    """Fuente de un punto: Google mezcla Air (FITBIT) y Apple Health (HEALTH_KIT) en la misma lista."""
    ds = pt.get("dataSource") or {}
    if ds.get("platform") == "FITBIT":
        return (ds.get("device") or {}).get("displayName") or "Fitbit (derivado)"
    if ds.get("platform") == "HEALTH_KIT":
        return "Apple Health (HealthKit)"
    return ds.get("platform") or "(sin fuente)"


def is_air(pt):
    """Sin `dataSource` (p. ej. rollups) se considera de la Air; si lo hay, solo FITBIT."""
    return "dataSource" not in pt or (pt["dataSource"] or {}).get("platform") == "FITBIT"


def split_source(points, source):
    """Devuelve (puntos_que_se_quedan, nº_de_otras_fuentes_descartadas)."""
    if source == "all":
        return points, 0
    kept = [p for p in points if is_air(p)]
    return kept, len(points) - len(kept)


def range_filter(data_type, days):
    """Filtro AIP-160 para los últimos `days` días, según el tipo de registro."""
    kind = AIR_TYPES.get(data_type)
    if kind is None:
        return None
    f = data_type.replace("-", "_")
    now = datetime.now(timezone.utc)
    start = now - timedelta(days=days)
    ts = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")
    day = lambda d: d.strftime("%Y-%m-%d")
    if kind == "interval":
        return f'{f}.interval.start_time >= "{ts(start)}"'
    if kind == "exercise":  # verificado: exercise NO admite start_time/end_time, solo civil_start_time
        return f'{f}.interval.civil_start_time >= "{day(start)}"'
    if kind == "sample":
        return f'{f}.sample_time.physical_time >= "{ts(start)}"'
    if kind == "daily":  # sintaxis de comparación sobre `.date` por confirmar
        return f'{f}.date >= "{day(start)}"'
    if kind == "sleep":  # el único filtro admitido para sleep es por fin de sesión
        return f'sleep.interval.end_time >= "{ts(start)}"'


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def client_creds():
    cid, secret = os.environ.get("GH_CLIENT_ID"), os.environ.get("GH_CLIENT_SECRET")
    if not cid:
        die("define GH_CLIENT_ID (y GH_CLIENT_SECRET si el cliente lo tiene)")
    return cid, secret


def post_form(url, data):
    req = urllib.request.Request(url, data=urllib.parse.urlencode(data).encode(), method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        die(f"{url} -> HTTP {e.code}: {e.read().decode(errors='replace')}")


def save_token(tok, prev=None):
    tok = dict(tok)
    if prev and "refresh_token" not in tok:
        tok["refresh_token"] = prev["refresh_token"]
    tok["obtained_at"] = int(time.time())
    if "refresh_token_issued_at" not in tok:
        tok["refresh_token_issued_at"] = (prev or {}).get("refresh_token_issued_at", tok["obtained_at"])
    TOKEN_FILE.write_text(json.dumps(tok, indent=2))
    os.chmod(TOKEN_FILE, 0o600)
    return tok


def cmd_auth(_args):
    cid, secret = client_creds()
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    q = {
        "client_id": cid, "redirect_uri": REDIRECT_URI, "response_type": "code",
        "scope": " ".join(SCOPES), "access_type": "offline", "prompt": "consent",
        "code_challenge": challenge, "code_challenge_method": "S256", "state": state,
    }
    result = {}

    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            p = urllib.parse.urlparse(self.path)
            if p.path != "/callback":
                self.send_response(404); self.end_headers(); return
            result.update({k: v[0] for k, v in urllib.parse.parse_qs(p.query).items()})
            self.send_response(200); self.send_header("Content-Type", "text/plain; charset=utf-8"); self.end_headers()
            self.wfile.write("Listo. Puedes cerrar esta pestaña.".encode())

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", REDIRECT_PORT), H)
    t = threading.Thread(target=srv.handle_request); t.start()
    url = AUTH_URL + "?" + urllib.parse.urlencode(q)
    print("Abre esta URL si el navegador no se abre solo:\n" + url)
    webbrowser.open(url)
    t.join(timeout=300)
    srv.server_close()
    if result.get("state") != state:
        die(f"state no coincide o no hubo callback: {result}")
    if "error" in result:
        die(f"Google devolvió error: {result}")
    data = {"code": result["code"], "client_id": cid, "redirect_uri": REDIRECT_URI,
            "grant_type": "authorization_code", "code_verifier": verifier}
    if secret:
        data["client_secret"] = secret
    tok = save_token(post_form(TOKEN_URL, data))
    print("OK. scopes concedidos:", tok.get("scope"))
    print("refresh_token presente:", "refresh_token" in tok)
    print(f"token guardado en {TOKEN_FILE}")
    status, body = api_get("users/me/identity")
    print(f"users.getIdentity -> HTTP {status}: {json.dumps(body, ensure_ascii=False)}")


def access_token():
    if not TOKEN_FILE.exists():
        die("no hay token: ejecuta `probe.py auth`")
    tok = json.loads(TOKEN_FILE.read_text())
    if time.time() < tok["obtained_at"] + tok.get("expires_in", 0) - 60:
        return tok["access_token"]
    cid, secret = client_creds()
    data = {"client_id": cid, "refresh_token": tok["refresh_token"], "grant_type": "refresh_token"}
    if secret:
        data["client_secret"] = secret
    age_days = (time.time() - tok.get("refresh_token_issued_at", tok["obtained_at"])) / 86400
    print(f"[refresh] refresh_token con {age_days:.1f} días", file=sys.stderr)
    return save_token(post_form(TOKEN_URL, data), tok)["access_token"]


def api_get(path, params=None):
    url = f"{API_BASE}/{path.lstrip('/')}"
    if params:
        url += "?" + urllib.parse.urlencode(params, doseq=True)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {access_token()}"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        try:
            body = json.loads(body)
        except ValueError:
            pass
        return e.code, body


def api_post(path, payload):
    url = f"{API_BASE}/{path.lstrip('/')}"
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), method="POST",
                                 headers={"Authorization": f"Bearer {access_token()}",
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        try:
            body = json.loads(body)
        except ValueError:
            pass
        return e.code, body


def civil(d):
    return {"date": {"year": d.year, "month": d.month, "day": d.day}, "time": {}}


def cmd_rollup(args):
    """dailyRollUp (POST) para tipos sin list, p. ej. total-calories. Máx. 14 días en total-calories."""
    end = datetime.now().date() + timedelta(days=1)
    start = end - timedelta(days=min(args.days, 14))
    body = {"range": {"start": civil(start), "end": civil(end)}, "windowSizeDays": 1}
    status, resp = api_post(f"users/me/dataTypes/{args.data_type}/dataPoints:dailyRollUp", body)
    print(f"HTTP {status}\n{json.dumps(resp, indent=2, ensure_ascii=False)[:3000]}")


def fetch_all(data_type, params, max_pages):
    pages, points, status = 0, [], 200
    token = None
    while pages < max_pages:
        p = dict(params)
        if token:
            p["pageToken"] = token
        status, body = api_get(f"users/me/dataTypes/{data_type}/dataPoints", p)
        if status != 200:
            return status, body, pages, points
        pages += 1
        points.extend(body.get("dataPoints", []) if isinstance(body, dict) else [])
        token = body.get("nextPageToken") if isinstance(body, dict) else None
        if not token:
            break
    return status, None, pages, points


def build_params(args):
    params = {}
    for kv in args.param or []:
        k, _, v = kv.partition("=")
        params[k] = v
    if args.page_size:
        params["pageSize"] = args.page_size
    if "filter" not in params and getattr(args, "days", None):
        flt = range_filter(args.data_type, args.days)
        if flt:
            params["filter"] = flt
    return params


def cmd_read(args):
    status, err, pages, points = fetch_all(args.data_type, build_params(args), args.max_pages)
    if err is not None:
        print(f"HTTP {status}\n{json.dumps(err, indent=2, ensure_ascii=False)}")
        return
    points, other = split_source(points, args.source)
    print(f"HTTP {status} · páginas={pages} · puntos={len(points)}"
          + (f" · otras fuentes descartadas={other}" if other else ""))
    for p in points[:3]:
        print(json.dumps(p, indent=2, ensure_ascii=False))


def cmd_matrix(args):
    rows = []
    for raw in CANDIDATE_TYPES:
        dt = raw
        params = {"pageSize": PAGE_SIZE_CAP.get(dt, 100)}
        flt = range_filter(dt, args.days)
        if flt:
            params["filter"] = flt
        status, err, pages, points = fetch_all(dt, params, 5)
        points, other = split_source(points, args.source)
        note = ""
        if err is not None:
            msg = err.get("error", {}).get("message", "") if isinstance(err, dict) else str(err)
            note = msg[:90].replace("\n", " ")
        elif points:
            first = points[0]
            note = "campos: " + ",".join(list(first)[:6]) if isinstance(first, dict) else ""
        rows.append((raw, status, pages, len(points), other, note))
    print(f"{'dataType':40} {'HTTP':>5} {'pág':>4} {'pts':>5} {'otras':>6}  nota")
    for r in rows:
        print(f"{r[0]:40} {r[1]:>5} {r[2]:>4} {r[3]:>5} {r[4] or '-':>6}  {r[5]}")
    print(f"\nventana: últimos {args.days} días (parámetro `filter`); fuente: {args.source}"
          " (`otras` = puntos de otras fuentes descartados, p. ej. Apple Health)")


def cmd_today(_args):
    """Pasos y distancia de hoy (medianoche local), por fuente, para comparar con la app."""
    now = datetime.now().astimezone()
    start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    for dt, field, unit, div in (("steps", "steps", "pasos", 1), ("distance", "distance", "km", 1_000_000)):
        flt = f'{dt}.interval.start_time >= "{start.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}"'
        status, err, _p, points = fetch_all(dt, {"filter": flt, "pageSize": 1000}, 20)
        if err is not None:
            print(f"{dt}: HTTP {status} {err}"); continue
        totals = {}
        for p in points:
            body = p.get(field) or {}
            v = body.get("count") or body.get("millimeters") or 0
            totals[source_name(p)] = totals.get(source_name(p), 0) + float(v)
        print(f"{dt} desde {start:%Y-%m-%d %H:%M} (hora local):")
        for name, v in sorted(totals.items(), key=lambda kv: -kv[1]):
            print(f"  {name:28} {v / div:>10.2f} {unit}" if div != 1 else f"  {name:28} {int(v):>10} {unit}")


def cmd_raw(args):
    status, body = api_get(args.path)
    print(f"HTTP {status}\n{json.dumps(body, indent=2, ensure_ascii=False)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("auth").set_defaults(fn=cmd_auth)
    r = sub.add_parser("read")
    r.add_argument("data_type")
    r.add_argument("--days", type=int, default=1)
    r.add_argument("--param", action="append", help="k=v extra (p. ej. el filtro de rango)")
    r.add_argument("--page-size", type=int)
    r.add_argument("--max-pages", type=int, default=3)
    r.add_argument("--source", choices=("air", "all"), default="air",
                   help="air (por defecto): solo puntos de la Air; all: mezcla Apple Health")
    r.set_defaults(fn=cmd_read)
    ru = sub.add_parser("rollup"); ru.add_argument("data_type", nargs="?", default="total-calories")
    ru.add_argument("--days", type=int, default=7); ru.set_defaults(fn=cmd_rollup)
    m = sub.add_parser("matrix"); m.add_argument("--days", type=int, default=14)
    m.add_argument("--source", choices=("air", "all"), default="air"); m.set_defaults(fn=cmd_matrix)
    sub.add_parser("today").set_defaults(fn=cmd_today)
    w = sub.add_parser("raw"); w.add_argument("path"); w.set_defaults(fn=cmd_raw)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
