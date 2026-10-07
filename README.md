# Wallpaper Change System

Herramienta para mantener un **fondo de escritorio uniforme** en equipos
**Windows 10/11**. Un servidor central publica una imagen y cada equipo la
aplica automáticamente cuando cambia.

Útil para cualquier organización, laboratorio, aula o parque de equipos que
necesite distribuir y actualizar el fondo de escritorio de forma centralizada,
sin depender de directivas de grupo.

## Contenido

```
.
├── wallpaper-server/     Servidor central: publica la imagen (Python, stdlib)
└── wallpaper-client/     Cliente Windows: aplica el fondo (PowerShell 5.1)
```

- **[wallpaper-server/](wallpaper-server/README.md)** — el servidor central:
  expone `/wallpaper` (JSON) y `/image`, calcula versión y sha256 desde el
  archivo, y permite cambiar el fondo reemplazando la imagen. Incluye guía de
  HTTPS (proxy inverso o certificado) y de despliegue como servicio.
- **[wallpaper-client/](wallpaper-client/README.md)** — el cliente de Windows:
  arquitectura, configuración, instalación, pruebas de extremo a extremo y
  solución de problemas.

## Arquitectura en una línea

```
  Servidor central  ──(HTTPS: JSON version/url/sha256 + imagen)──►  Cliente Windows
  (publica imagen)                                                  (valida y aplica el fondo)
```

El cliente solo descarga una imagen validada (tamaño, formato y sha256); nunca
ejecuta nada que venga del servidor y solo acepta URLs **https** (TLS 1.2).

## Configuración (datos que debe poner cada organización)

Este repositorio **no contiene datos sensibles**: no incluye la dirección real
del servidor, ni certificados, ni credenciales. Todos esos valores los configura
cada organización en su despliegue. En los archivos de configuración verá
marcadores de posición como `tu-servidor.example.com` que **debe reemplazar** por
los suyos.

| Dato a configurar | Dónde | Marcador por defecto |
|-------------------|-------|----------------------|
| Dirección del servidor (IP o dominio) | [`wallpaper-client/config.json`](wallpaper-client/config.json) → `serverUrl` | `https://tu-servidor.example.com/wallpaper` |
| Misma dirección, lado servidor | [`wallpaper-server/config.json`](wallpaper-server/config.json) → `publicBaseUrl` | `https://tu-servidor.example.com` |
| Certificado y clave TLS | servidor (proxy inverso o `certFile`/`keyFile`) | — (no se versiona) |
| Imagen a publicar | `wallpaper-server/wallpapers/` | — (no se versiona) |

Recomendaciones:

- **No** haga commit de la dirección real del servidor, certificados, claves ni
  imágenes internas. Configúrelos solo en el equipo donde corre cada componente.
- La dirección del servidor debe apuntar al **mismo** sitio en cliente
  (`serverUrl`) y servidor (`publicBaseUrl`).
- Detalle de cada campo: ver los README de
  [servidor](wallpaper-server/README.md) y [cliente](wallpaper-client/README.md).

## Inicio rápido

Cada componente tiene su propia documentación
([servidor](wallpaper-server/README.md) · [cliente](wallpaper-client/README.md)).
En resumen:

1. **Servidor** ([`wallpaper-server/`](wallpaper-server/README.md)): coloque la
   imagen en `wallpaper-server/wallpapers/`, ejecute `python server.py` y
   expóngalo por https. Publica `/wallpaper` (JSON) y `/image`.
2. **Cliente** ([`wallpaper-client/`](wallpaper-client/README.md)): edite
   `wallpaper-client/config.json` y ejecute `install.ps1` como administrador en
   cada equipo Windows.

## Seguridad

Este proyecto es **código abierto y auditable**: el cliente y el servidor son
scripts legibles (PowerShell y Python con librería estándar), sin binarios,
sin ofuscación y sin dependencias externas. Puede revisar exactamente qué hacen.

Qué lo hace seguro por diseño:

- El cliente **solo descarga una imagen y la valida** (tamaño máximo, bytes
  mágicos de JPG/PNG/BMP y sha256). **Nunca ejecuta ni interpreta** nada que
  envíe el servidor.
- **Solo acepta HTTPS** (fuerza TLS 1.2). No hay telemetría ni llamadas a
  terceros: solo habla con el servidor que usted configure.
- El cliente corre con **privilegios limitados** (grupo `Users`), nunca como
  SYSTEM ni administrador. Solo la instalación requiere permisos de admin.

### Por qué su antivirus podría marcarlo

El cliente usa técnicas de administración legítimas que también aparecen en
software malicioso, así que un antivirus/EDR estricto podría señalarlo. Están a
la vista en el código:

- lanzar PowerShell en ventana oculta (`-WindowStyle Hidden`) mediante un `.vbs`,
- usar `-ExecutionPolicy Bypass` al invocar el script,
- registrar una tarea programada que se ejecuta periódicamente.

Son inherentes a la función de un cliente de este tipo. Si su AV lo bloquea,
revise el código y, si lo aprueba, agregue una exclusión.

### Recomendaciones para el despliegue

- **Asegure el servidor:** quien controle el servidor controla el fondo que se
  aplica en todos los equipos. Use un certificado HTTPS de confianza.
- El servidor **no incluye autenticación**: cualquiera que alcance el endpoint
  obtiene la imagen. Es normal para un fondo de escritorio; no publique datos
  confidenciales por esa vía.
- **No suba a git** la dirección real del servidor, certificados ni imágenes
  internas: configúrelos solo en cada despliegue.
