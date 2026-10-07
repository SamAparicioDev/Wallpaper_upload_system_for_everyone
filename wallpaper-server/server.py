#!/usr/bin/env python3
"""
wallpaper-server — servidor central de fondos de escritorio.

Publica una imagen para que los equipos con wallpaper-client la apliquen.
Usa SOLO la librería estándar de Python 3 (sin dependencias).

Expone dos rutas (los nombres se configuran en config.json):

  GET /wallpaper   -> JSON { "version": "...", "url": "...", "sha256": "..." }
  GET /image       -> los bytes de la imagen actual

La `version` y el `sha256` se calculan a partir del CONTENIDO del archivo de
imagen, por lo que **cambiar el fondo para todos es tan simple como reemplazar
ese archivo**: la versión cambia sola y los clientes lo detectan.

Configuración (config.json junto a este script, o --config):

  host           Interfaz donde escucha (0.0.0.0 = todas).
  port           Puerto de escucha.
  imagePath      Ruta al archivo de imagen a servir.
  publicBaseUrl  Base pública HTTPS con la que el cliente arma la URL de la
                 imagen (p. ej. https://tu-servidor.example.com). Debe ser https.
  endpointPath   Ruta del JSON (por defecto /wallpaper).
  imagePathUrl   Ruta de la imagen (por defecto /image).
  certFile/keyFile  Certificado y clave TLS (PEM) para servir por HTTPS
                 directamente; si se dejan vacíos, sirve HTTP plano (pensado
                 para ir detrás de un proxy inverso con TLS).

Cualquier opción se puede sobreescribir por línea de comandos; ver --help.

NOTA SOBRE HTTPS
----------------
El cliente exige https tanto para el endpoint como para la URL de la imagen.
En producción, lo habitual es poner este servidor detrás de un proxy inverso
(nginx, Caddy, IIS) que termina TLS en el 443 y reenvía al puerto local. En ese
caso deje certFile/keyFile vacíos y ponga publicBaseUrl con la URL https pública.
Para una prueba directa sin proxy, genere un certificado y rellene certFile/keyFile
(Windows deberá confiar en ese certificado).
"""

import argparse
import hashlib
import json
import os
import ssl
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def guess_content_type(path):
    ext = os.path.splitext(path)[1].lower()
    return {
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".png": "image/png",
        ".bmp": "image/bmp",
    }.get(ext, "application/octet-stream")


def load_config(config_path):
    cfg = {
        "host": "0.0.0.0",
        "port": 8000,
        "imagePath": "wallpapers/wallpaper.jpg",
        "publicBaseUrl": "",
        "endpointPath": "/wallpaper",
        "imagePathUrl": "/image",
        "certFile": "",
        "keyFile": "",
    }
    if config_path and os.path.isfile(config_path):
        with open(config_path, "r", encoding="utf-8") as f:
            cfg.update(json.load(f))
    return cfg


class Handler(BaseHTTPRequestHandler):
    # Inyectados por make_handler
    image_path = None
    public_base = None
    endpoint_path = "/wallpaper"
    image_url_path = "/image"

    def _send_json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"

        if path == self.endpoint_path.rstrip("/"):
            if not os.path.isfile(self.image_path):
                self._send_json(404, {"error": "no hay imagen configurada"})
                return
            sha = file_sha256(self.image_path)
            if self.public_base:
                base = self.public_base.rstrip("/")
            else:
                host = self.headers.get("Host", "localhost")
                base = "http://{}".format(host)
            self._send_json(200, {
                "version": sha[:16],
                "url": base + self.image_url_path,
                "sha256": sha,
            })
            return

        if path == self.image_url_path.rstrip("/"):
            if not os.path.isfile(self.image_path):
                self._send_json(404, {"error": "no hay imagen configurada"})
                return
            ctype = guess_content_type(self.image_path)
            size = os.path.getsize(self.image_path)
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(size))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            with open(self.image_path, "rb") as f:
                while True:
                    chunk = f.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
            return

        self._send_json(404, {"error": "ruta no encontrada"})

    def log_message(self, fmt, *args):
        print("[wallpaper-server] " + (fmt % args))


def make_handler(cfg):
    attrs = {
        "image_path": os.path.abspath(cfg["imagePath"]),
        "public_base": cfg.get("publicBaseUrl") or None,
        "endpoint_path": cfg.get("endpointPath", "/wallpaper"),
        "image_url_path": cfg.get("imagePathUrl", "/image"),
    }
    return type("BoundHandler", (Handler,), attrs)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser(description="wallpaper-server")
    parser.add_argument("--config", default=os.path.join(here, "config.json"),
                        help="Ruta a config.json")
    parser.add_argument("--host")
    parser.add_argument("--port", type=int)
    parser.add_argument("--image", help="Ruta al archivo de imagen")
    parser.add_argument("--public-base", help="Base pública https, ej: https://tu-servidor.example.com")
    parser.add_argument("--certfile")
    parser.add_argument("--keyfile")
    args = parser.parse_args()

    cfg = load_config(args.config)
    # Las rutas relativas del config se resuelven respecto a la carpeta del server.
    if not os.path.isabs(cfg["imagePath"]):
        cfg["imagePath"] = os.path.join(here, cfg["imagePath"])

    # Overrides por CLI
    if args.host:        cfg["host"] = args.host
    if args.port:        cfg["port"] = args.port
    if args.image:       cfg["imagePath"] = os.path.abspath(args.image)
    if args.public_base: cfg["publicBaseUrl"] = args.public_base
    if args.certfile:    cfg["certFile"] = args.certfile
    if args.keyfile:     cfg["keyFile"] = args.keyfile

    handler = make_handler(cfg)
    httpd = ThreadingHTTPServer((cfg["host"], int(cfg["port"])), handler)

    scheme = "http"
    if cfg.get("certFile") and cfg.get("keyFile"):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(certfile=cfg["certFile"], keyfile=cfg["keyFile"])
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
        scheme = "https"

    print("wallpaper-server")
    print("  Escuchando en {}://{}:{}".format(scheme, cfg["host"], cfg["port"]))
    print("  Imagen:       {}".format(cfg["imagePath"]))
    print("  Endpoint:     {}://{}:{}{}".format(scheme, cfg["host"], cfg["port"], cfg["endpointPath"]))
    if cfg.get("publicBaseUrl"):
        print("  URL pública:  {}{}".format(cfg["publicBaseUrl"].rstrip("/"), cfg["endpointPath"]))
    if not os.path.isfile(cfg["imagePath"]):
        print("  AVISO: todavía no existe la imagen. Coloque un archivo en la ruta de arriba.",
              file=sys.stderr)
    print("  Para cambiar el fondo: reemplace el archivo de imagen y listo.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nDeteniendo servidor...")
        httpd.shutdown()


if __name__ == "__main__":
    main()
