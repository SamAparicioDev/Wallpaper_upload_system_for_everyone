# wallpaper-server

Servidor central de fondos de escritorio. Publica una imagen para que los
equipos con [wallpaper-client](../wallpaper-client/README.md) la apliquen
automáticamente cuando cambia.

Usa **solo la librería estándar de Python 3** (sin dependencias).

---

## Qué hace

Expone dos rutas por HTTP(S):

| Ruta         | Devuelve                                                              |
|--------------|-----------------------------------------------------------------------|
| `/wallpaper` | JSON `{ "version", "url", "sha256" }` calculado desde la imagen.       |
| `/image`     | Los bytes de la imagen actual.                                        |

La `version` y el `sha256` se derivan del **contenido** del archivo de imagen,
así que **cambiar el fondo para todos es tan simple como reemplazar el archivo**:
la versión cambia sola y los clientes lo detectan en su siguiente comprobación.

---

## Requisitos

- **Python 3** (cualquier versión reciente). Sin dependencias externas.

---

## Configuración (`config.json`)

```json
{
  "host": "0.0.0.0",
  "port": 8000,
  "imagePath": "wallpapers/wallpaper.jpg",
  "publicBaseUrl": "https://tu-servidor.example.com",
  "endpointPath": "/wallpaper",
  "imagePathUrl": "/image",
  "certFile": "",
  "keyFile": ""
}
```

| Campo           | Descripción                                                                                      |
|-----------------|--------------------------------------------------------------------------------------------------|
| `host`          | Interfaz donde escucha (`0.0.0.0` = todas).                                                       |
| `port`          | Puerto de escucha.                                                                               |
| `imagePath`     | Ruta al archivo de imagen a servir (relativa a esta carpeta).                                     |
| `publicBaseUrl` | Base pública **https** con la que el cliente arma la URL de la imagen. **Debe configurarla** con la dirección real de su servidor; el valor `tu-servidor.example.com` es solo un marcador de posición. |
| `endpointPath`  | Ruta del JSON (debe coincidir con el `serverUrl` del cliente). Por defecto `/wallpaper`.          |
| `imagePathUrl`  | Ruta de la imagen. Por defecto `/image`.                                                          |
| `certFile`/`keyFile` | Certificado y clave TLS (PEM) para servir HTTPS directamente. Vacíos = HTTP plano (para ir detrás de un proxy inverso). |

Todo se puede sobreescribir por línea de comandos (`python server.py --help`).

> **Datos sensibles:** `publicBaseUrl` (la dirección real de su servidor), los
> certificados TLS y la imagen son propios de su despliegue. **No los suba a
> git**: configúrelos solo en el servidor. El repositorio solo trae marcadores
> de posición.

---

## Arranque

1. Coloque la imagen en `wallpapers/wallpaper.jpg` (o la ruta que indique `imagePath`).
2. Ejecute:

   ```bash
   cd wallpaper-server
   python server.py
   ```

   Verá algo como:

   ```
   wallpaper-server
     Escuchando en http://0.0.0.0:8000
     Endpoint:     http://0.0.0.0:8000/wallpaper
     URL pública:  https://tu-servidor.example.com/wallpaper
   ```

3. Compruebe:

   ```bash
   curl http://localhost:8000/wallpaper
   # {"version":"3c4bae649b6c0fad","url":"https://tu-servidor.example.com/image","sha256":"3c4bae..."}
   ```

---

## HTTPS (obligatorio para el cliente)

El cliente **exige https**. Dos formas:

### Opción recomendada: proxy inverso con TLS

Deje `certFile`/`keyFile` vacíos (el server habla HTTP plano en el puerto local)
y ponga delante un proxy que termine TLS en el 443. Ejemplo con **nginx**:

```nginx
server {
    listen 443 ssl;
    server_name tu-servidor.example.com;

    ssl_certificate     /ruta/fullchain.pem;
    ssl_certificate_key /ruta/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8000;
    }
}
```

Con esto, el cliente usa `https://tu-servidor.example.com/wallpaper` y el proxy reenvía
al servidor local en el 8000. `publicBaseUrl` ya apunta a esa URL pública.

### Opción prueba directa: TLS en el propio server

Genere un certificado y rellene `certFile`/`keyFile` (o use `--certfile`/`--keyfile`):

```bash
python server.py --certfile cert.pem --keyfile key.pem \
    --public-base https://tu-servidor.example.com:8000 --port 8000
```

Windows deberá **confiar** en ese certificado; si no, la descarga del cliente
fallará con error de red.

---

## Dejarlo corriendo (Linux, systemd)

Ejemplo de unidad `/etc/systemd/system/wallpaper-server.service`:

```ini
[Unit]
Description=wallpaper-server
After=network.target

[Service]
WorkingDirectory=/opt/wallpaper-server
ExecStart=/usr/bin/python3 /opt/wallpaper-server/server.py
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now wallpaper-server
```

---

## Cambiar el fondo

Reemplace el archivo de imagen (`wallpapers/wallpaper.jpg`). Nada más: en la
siguiente comprobación, cada cliente detectará la nueva `version` y actualizará
el fondo.

---

## Relación con el cliente

El `serverUrl` del cliente debe apuntar a este `endpointPath`:

- Cliente: [`wallpaper-client/config.json`](../wallpaper-client/config.json) →
  `"serverUrl": "https://tu-servidor.example.com/wallpaper"`
- Servidor: `publicBaseUrl` + `endpointPath` = `https://tu-servidor.example.com/wallpaper`

Formato del JSON y validaciones que hace el cliente: ver
[wallpaper-client/README.md](../wallpaper-client/README.md).
