#!/usr/bin/env python3
"""Minimaler UCM-Ersatz: liefert /api/v2/ssh/cas/3/krl über HTTPS mit API-Schlüssel."""
import http.server
import ssl
import sys

work = sys.argv[1]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("X-API-Key") != "ucm_ak_TESTKEY" or self.path != "/api/v2/ssh/cas/3/krl":
            self.send_response(401)
            self.end_headers()
            return
        with open(f"{work}/served.krl", "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


server = http.server.HTTPServer(("127.0.0.1", 8443), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(f"{work}/tls.crt", f"{work}/tls.key")
server.socket = ctx.wrap_socket(server.socket, server_side=True)
server.serve_forever()
