# WallpaperClient

Cliente para **Windows** que cambia el fondo de escritorio cuando un servidor
central publica una imagen nueva. Cada estación consulta periódicamente un
endpoint; si la versión publicada cambió, descarga la imagen, la **valida** y la
aplica como fondo del usuario que tiene la sesión iniciada.

Pensado para entornos donde hay que mantener un fondo corporativo uniforme sin
depender de directivas de grupo.

---

## Índice

- [Cómo funciona (visión general)](#cómo-funciona-visión-general)
- [Requisitos](#requisitos)
- [Estructura del proyecto](#estructura-del-proyecto)
- [Parte A — El servidor](#parte-a--el-servidor)
  - [A.1 Qué tiene que exponer el servidor](#a1-qué-tiene-que-exponer-el-servidor)
  - [A.2 Usar wallpaper-server](#a2-usar-wallpaper-server)
- [Parte B — Configuración del lado del CLIENTE](#parte-b--configuración-del-lado-del-cliente)
  - [B.1 Editar config.json](#b1-editar-configjson)
  - [B.2 Instalar](#b2-instalar)
  - [B.3 Probar sin instalar](#b3-probar-sin-instalar)
  - [B.4 Desinstalar](#b4-desinstalar)
- [Prueba de extremo a extremo](#prueba-de-extremo-a-extremo)
- [Solución de problemas](#solución-de-problemas)
- [Notas de seguridad](#notas-de-seguridad)

---

## Cómo funciona (visión general)

```
  ┌─────────────────────┐          GET /wallpaper (https)         ┌──────────────────────┐
  │      SERVIDOR        │ <───────────────────────────────────── │       CLIENTE        │
  │                      │                                         │  (cada N minutos,    │
  │  /wallpaper → JSON   │ ──────────────────────────────────────>│   tarea programada)  │
  │  { version, url,     │   { "version","url","sha256" }          │                      │
  │    sha256 }          │                                         │  1. ¿cambió version? │
  │                      │          GET url (https)                │  2. descarga imagen  │
  │  /image → bytes      │ <───────────────────────────────────── │  3. valida           │
  │                      │ ──────────────────────────────────────>│  4. aplica el fondo  │
  └─────────────────────┘           (bytes de imagen)             └──────────────────────┘
```

1. El **servidor** publica un JSON con una `version`, la `url` de la imagen y
   (opcional) su `sha256`.
2. El **cliente** compara esa `version` con la última que aplicó. Si no cambió,
   no hace nada.
3. Si cambió, descarga la imagen, la valida (tamaño, formato, sha256) y la
   aplica como fondo. Solo entonces guarda la nueva versión.

---

## Requisitos

### Cliente (Windows)
- **Windows 10 u 11**, cualquier edición (Home, Pro, Enterprise, Education).
- **Windows PowerShell 5.1** (el de fábrica) y componentes nativos. **No**
  requiere módulos externos, **no** instala .NET adicional, **no** instala nada
  más.
- **No** depende de directivas de grupo (funciona igual en Home).
- Permisos de **Administrador** solo para instalar/desinstalar. El cliente en sí
  corre con privilegios limitados.

### Servidor
- Cualquier servidor que exponga el endpoint descrito en la [Parte A](#parte-a--el-servidor) por **https**.
- En este repositorio se incluye **[`wallpaper-server`](../wallpaper-server/README.md)**
  (Python 3, solo librería estándar), que ya cumple ese contrato.

---

## Estructura del proyecto

```
wallpaper-client/
├── install.ps1           Instala y registra la tarea programada (como admin)
├── uninstall.ps1         Elimina tarea, archivos y (opcional) estado
├── wallpaper-client.ps1  Lógica del cliente (una pasada por ejecución)
├── config.json           Configuración del CLIENTE
└── README.md

(El servidor es un componente aparte: ../wallpaper-server/)
```

---

# Parte A — El servidor

El servidor vive en su propio componente: **[`wallpaper-server`](../wallpaper-server/README.md)**
(carpeta hermana de esta). Allí está toda la documentación para arrancarlo,
configurarlo, ponerlo tras HTTPS y dejarlo corriendo.

Esta sección solo describe **el contrato** que el cliente espera del servidor,
para que el cliente funcione con `wallpaper-server` o con cualquier otro servidor
equivalente.

## A.1 Qué tiene que exponer el servidor

El servidor debe ofrecer **dos cosas** por **https**:

### 1) Un endpoint que devuelve JSON

Es la URL que pondrá en `serverUrl` del cliente. Responde con este JSON:

```json
{
  "version": "una-cadena-que-cambia-cuando-cambia-la-imagen",
  "url": "https://tu-servidor.example.com/image",
  "sha256": "opcional-pero-recomendado"
}
```

| Campo     | Obligatorio | Descripción                                                                                 |
|-----------|-------------|---------------------------------------------------------------------------------------------|
| `version` | Sí          | El cliente guarda la última versión aplicada y **solo actúa cuando cambia**. Puede ser un hash, una fecha, un número de build… lo que quiera, siempre que cambie al cambiar la imagen. |
| `url`     | Sí          | URL **https** desde la que el cliente descargará la imagen.                                  |
| `sha256`  | No          | Si viene, el cliente verifica que la imagen descargada coincida; si no, la rechaza y **no toca** el fondo. Muy recomendable. |

### 2) La imagen

La imagen a la que apunta `url`. Debe ser **JPG, PNG o BMP** y servirse por
**https**.

> **Recomendación:** derive `version` y `sha256` del **contenido** del archivo
> (su hash sha256). Así, al reemplazar la imagen, la versión cambia sola y no hay
> que acordarse de tocar nada más. `wallpaper-server` ya lo hace.

## A.2 Usar `wallpaper-server`

Es el servidor incluido en este repositorio y ya cumple el contrato de A.1.
Resumen:

```bash
cd ../wallpaper-server
# coloque la imagen en wallpapers/wallpaper.jpg
python server.py
```

Expone `/wallpaper` (el JSON) y `/image` (la imagen), y calcula `version` y
`sha256` desde el archivo. Para cambiar el fondo de todos los equipos, **reemplace
la imagen**. Configuración, HTTPS (proxy inverso o certificado) y cómo dejarlo
como servicio: ver **[wallpaper-server/README.md](../wallpaper-server/README.md)**.

El cliente **exige https** (y fuerza TLS 1.2) tanto para `serverUrl` como para la
`url` de la imagen; `wallpaper-server` documenta las dos formas de cumplirlo
(proxy inverso con TLS, o certificado en el propio servidor).

---

# Parte B — Configuración del lado del CLIENTE

## B.1 Editar `config.json`

Antes de instalar, edite `config.json` con los datos de **su** servidor:

```json
{
  "serverUrl": "https://tu-servidor.example.com/wallpaper",
  "intervalMinutes": 15,
  "style": "fill",
  "maxSizeMB": 20,
  "timeoutSeconds": 30
}
```

> **Debe configurar `serverUrl`.** Viene con el marcador de posición
> `https://tu-servidor.example.com/wallpaper`, que **no es un servidor real**.
> Reemplácelo por la dirección (IP o dominio) de su servidor. Debe ser siempre
> **https**. No suba a git la dirección real de su organización.

| Campo             | Descripción                                                                                   |
|-------------------|-----------------------------------------------------------------------------------------------|
| `serverUrl`       | Endpoint **https** que devuelve el JSON (el de la [Parte A](#a1-qué-tiene-que-exponer-el-servidor)). **Obligatorio configurarlo**; el valor por defecto es solo un marcador de posición. |
| `intervalMinutes` | Cada cuántos minutos el cliente comprueba si hay fondo nuevo (lo usa la tarea programada).     |
| `style`           | Ajuste del fondo: `fill` \| `fit` \| `stretch` \| `center` \| `tile` \| `span`.               |
| `maxSizeMB`       | Tamaño máximo aceptado para la imagen descargada (si lo supera, la rechaza).                   |
| `timeoutSeconds`  | Tiempo máximo de espera para la consulta y la descarga.                                        |

**Estilos** (equivalen al "Ajuste" del fondo de Windows):

| Estilo    | Efecto                                                      |
|-----------|-------------------------------------------------------------|
| `fill`    | Rellenar (recorta para cubrir toda la pantalla)             |
| `fit`     | Ajustar (imagen completa, con bandas si hace falta)         |
| `stretch` | Estirar (deforma para cubrir)                               |
| `center`  | Centrar                                                     |
| `tile`    | Mosaico                                                     |
| `span`    | Expandir en varios monitores (Windows 8+/10/11)            |

> **Importante:** el instalador copia `config.json` **tal cual**. Deje la
> configuración correcta antes de ejecutar `install.ps1`. Si luego cambia la
> config, vuelva a ejecutar `install.ps1` (es idempotente) o edite directamente
> `C:\ProgramData\WallpaperClient\config.json`.

## B.2 Instalar

1. Edite `config.json` (paso B.1).
2. Abra **PowerShell como Administrador**.
3. Ejecute:

   ```powershell
   cd <carpeta donde está install.ps1>
   powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
   ```

Qué hace el instalador:

- Copia `wallpaper-client.ps1` y `config.json` a `C:\ProgramData\WallpaperClient`.
- Crea un lanzador oculto (`run-hidden.vbs`) para que **no parpadee** ninguna
  consola.
- Registra una **tarea programada** llamada `WallpaperClient` que:
  - Se dispara **al iniciar sesión de cualquier usuario** (no al arrancar el
    equipo).
  - Se ejecuta como el usuario que inicia sesión, usando el grupo
    **`BUILTIN\Users` (SID S-1-5-32-545)** con **privilegios limitados**.
    Nunca como SYSTEM (el fondo es por usuario y SYSTEM corre en la sesión 0).
  - Se **repite cada N minutos** de forma indefinida (según `intervalMinutes`).
  - Se ejecuta aunque el equipo esté con batería, se inicia en cuanto puede si
    se perdió una ejecución, no lanza instancias en paralelo y tiene un límite
    de tiempo corto (5 min).

Es **idempotente**: volver a ejecutar `install.ps1` actualiza los archivos y la
tarea **sin duplicarla**.

## B.3 Probar sin instalar

Para probar el cliente a mano (sin registrar la tarea), desde la carpeta del
proyecto:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\wallpaper-client.ps1 -Force
```

`-Force` reaplica el fondo **aunque la versión no haya cambiado** (útil para
pruebas). Revise el log en `%LOCALAPPDATA%\WallpaperClient\client.log`.

## B.4 Desinstalar

Desde **PowerShell como Administrador**:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Esto quita la tarea programada y borra `C:\ProgramData\WallpaperClient`.

Para borrar **también** el estado por usuario (versión guardada, log e imágenes
descargadas en `%LOCALAPPDATA%\WallpaperClient`) del usuario actual:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -RemoveUserState
```

> El estado vive en el perfil de **cada** usuario. `-RemoveUserState` solo borra
> el del usuario que ejecuta el script.

---

## Prueba de extremo a extremo

Junta las dos partes anteriores en un flujo completo:

**1. (Servidor) Arranque [`wallpaper-server`](../wallpaper-server/README.md)** con una imagen:

```bash
cd ../wallpaper-server
# coloque la imagen en wallpapers/wallpaper.jpg
python server.py --port 8000
curl http://localhost:8000/wallpaper   # debe devolver el JSON
```

**2. (Servidor) Exponga por https** (proxy inverso o certificado; ver
[wallpaper-server/README.md](../wallpaper-server/README.md)) y anote la URL https
del endpoint `/wallpaper`.

**3. (Cliente) Configure `config.json`** con esa URL en `serverUrl`
(ver [B.1](#b1-editar-configjson)).

**4. (Cliente) Ejecute el cliente** a mano para la primera prueba:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\wallpaper-client.ps1 -Force
```

El fondo debería cambiar. Si no, revise el log (ver más abajo).

**5. (Cliente) Instale** la tarea programada
(ver [B.2](#b2-instalar)) y verifíquela:

```powershell
Get-ScheduledTask -TaskName WallpaperClient | Format-List *
Start-ScheduledTask -TaskName WallpaperClient
```

**6. (Servidor) Cambie el fondo para todos:** reemplace el archivo de imagen en
el servidor. En la siguiente pasada del cliente, el fondo se actualizará solo.

---

## Solución de problemas

**¿Dónde está el log?**

```
%LOCALAPPDATA%\WallpaperClient\client.log
```

(y su rotación `client.log.1`). El estado (última versión aplicada) está en
`%LOCALAPPDATA%\WallpaperClient\state.json` y las imágenes descargadas en
`%LOCALAPPDATA%\WallpaperClient\images`.

**Ejecutar la tarea a mano (sin esperar al intervalo):**

```powershell
Start-ScheduledTask -TaskName WallpaperClient
```

**Ejecutar el cliente directamente (para ver errores en pantalla):**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\WallpaperClient\wallpaper-client.ps1" -Force
```

**Códigos de salida del cliente:**

| Código | Significado                                               |
|--------|-----------------------------------------------------------|
| 0      | OK (sin cambios, o fondo aplicado)                        |
| 1      | Error de configuración (`config.json`)                    |
| 2      | Error de red / servidor (no se tocó el fondo)             |
| 3      | Imagen inválida: tamaño, formato o sha256 (no se tocó)    |
| 4      | Error al aplicar el fondo                                 |

**Si el fondo no cambia, revise:**

1. **El log** (`client.log`): casi siempre dice exactamente qué pasó.
2. Que `serverUrl` sea **https** y responda el JSON correcto
   (pruébelo con `curl` o el navegador).
3. Que la `version` del servidor **haya cambiado** respecto a la guardada en
   `state.json`. Para forzar, ejecute con `-Force`.
4. Que la imagen pase las validaciones (formato JPG/PNG/BMP real, tamaño ≤
   `maxSizeMB`, `sha256` correcto si se envía).
5. Que la **tarea exista y esté habilitada**:
   `Get-ScheduledTask -TaskName WallpaperClient`.
6. Que haya una **sesión interactiva iniciada**: el fondo es por usuario; la
   tarea se dispara al iniciar sesión y se repite mientras la sesión está
   activa.
7. Que Windows **confíe en el certificado** si usa https autofirmado (si no, la
   descarga falla con error de red → código 2).
8. Algunas configuraciones de alto contraste pueden ignorar el fondo;
   verifique que no esté activo el modo de alto contraste.

---

## Notas de seguridad

- El cliente **solo** descarga una imagen y la valida; nunca ejecuta ni
  interpreta contenido del servidor.
- Solo acepta URLs **https** (fuerza **TLS 1.2**).
- Corre con **privilegios limitados** (grupo Users), no como SYSTEM ni como
  administrador.
- Ante cualquier error (red, servidor, imagen inválida) **no modifica** el fondo
  actual y lo registra en el log.
