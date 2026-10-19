#!/usr/bin/env python3
"""Receptor mínimo para la Prueba 3.6: guarda en JSONL cada muestra HR que manda la sonda iOS.

  python3 receiver.py [puerto]      # por defecto 8787, escucha en 0.0.0.0
Después apunta la sonda a http://<IP-de-tu-ordenador>:8787/hr (misma wifi).
Calcula el retraso medio entre la marca de tiempo del iPhone y la recepción (requiere relojes en hora).
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

LOG = Path(__file__).with_name("logs"); LOG.mkdir(exist_ok=True)
OUT = open(LOG / f"hr-{int(time.time())}.jsonl", "a", buffering=1)
n = 0


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        global n
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        now = time.time()
        try:
            d = json.loads(body)
        except ValueError:
            self.send_response(400); self.end_headers(); return
        d["recv_t"] = now
        OUT.write(json.dumps(d) + "\n")
        n += 1
        if "t" in d:
            print(f"#{n} bpm={d.get('bpm')} rr={d.get('rr_ms')} lag={(now - d['t']) * 1000:.0f} ms")
        self.send_response(204); self.end_headers()

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    print(f"escuchando en 0.0.0.0:{port}; log en {OUT.name}")
    HTTPServer(("0.0.0.0", port), H).serve_forever()
