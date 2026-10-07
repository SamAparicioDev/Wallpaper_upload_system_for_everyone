<#
.SYNOPSIS
    Cliente de fondo de escritorio. Consulta un servidor central y, si hay una
    version nueva de imagen, la descarga, valida y aplica como wallpaper del
    usuario actual.

.DESCRIPTION
    Pensado para Windows 10/11 (todas las ediciones) usando SOLO Windows
    PowerShell 5.1 y componentes nativos. No requiere modulos externos ni
    instalar nada adicional.

    Cada ejecucion hace una sola pasada y termina. La repeticion la gestiona la
    Tarea Programada creada por install.ps1.

.PARAMETER Force
    Reaplica el fondo aunque la version no haya cambiado. Util para pruebas
    manuales.

.PARAMETER ConfigPath
    Ruta alternativa a config.json. Por defecto, el config.json junto a este
    script.

.NOTES
    Codigos de salida:
      0  = OK (sin cambios, o fondo aplicado correctamente)
      1  = Error de configuracion (config.json invalido / ausente)
      2  = Error de red o del servidor (no se toca el fondo actual)
      3  = Imagen invalida (tamano / formato / sha256) (no se toca el fondo)
      4  = Error al aplicar el fondo
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$ConfigPath
)

# No detenerse en el primer error: controlamos los errores manualmente para
# poder devolver codigos de salida significativos y nunca romper el fondo.
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Rutas y constantes
# ---------------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $ScriptDir 'config.json'
}

# Estado y log son POR USUARIO (el fondo es por usuario).
$StateDir   = Join-Path $env:LOCALAPPDATA 'WallpaperClient'
$StateFile  = Join-Path $StateDir 'state.json'
$LogFile    = Join-Path $StateDir 'client.log'
$ImageDir   = Join-Path $StateDir 'images'

$LogMaxBytes = 1MB   # rotacion por tamano

# ---------------------------------------------------------------------------
# Logging con rotacion por tamano
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    try {
        if (-not (Test-Path $StateDir)) {
            New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
        }
        # Rotacion simple: si supera el tamano, se renombra a .1 (se pisa el anterior).
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -ge $LogMaxBytes)) {
            $old = "$LogFile.1"
            if (Test-Path $old) { Remove-Item $old -Force -ErrorAction SilentlyContinue }
            Move-Item $LogFile $old -Force -ErrorAction SilentlyContinue
        }
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -Path $LogFile -Value "[$stamp] [$Level] $Message" -Encoding UTF8
    } catch {
        # Si ni siquiera podemos loguear, no hay mucho mas que hacer.
    }
}

function Exit-With {
    param([int]$Code, [string]$Message, [string]$Level = 'INFO')
    if ($Message) { Write-Log -Message $Message -Level $Level }
    exit $Code
}

# ---------------------------------------------------------------------------
# Mapeo de estilo -> valores de registro
#   WallpaperStyle / TileWallpaper en HKCU\Control Panel\Desktop
# ---------------------------------------------------------------------------
function Get-StyleRegistryValues {
    param([string]$Style)
    # @{ WallpaperStyle = '..'; TileWallpaper = '..' }
    switch ($Style.ToLowerInvariant()) {
        'fill'    { @{ WallpaperStyle = '10'; TileWallpaper = '0' } }
        'fit'     { @{ WallpaperStyle = '6';  TileWallpaper = '0' } }
        'stretch' { @{ WallpaperStyle = '2';  TileWallpaper = '0' } }
        'center'  { @{ WallpaperStyle = '0';  TileWallpaper = '0' } }
        'tile'    { @{ WallpaperStyle = '0';  TileWallpaper = '1' } }
        'span'    { @{ WallpaperStyle = '22'; TileWallpaper = '0' } }  # Win8+/10/11
        default   { $null }
    }
}

# ---------------------------------------------------------------------------
# Validacion de bytes magicos (firma de archivo)
# ---------------------------------------------------------------------------
function Test-ImageMagic {
    param([string]$Path)
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] 8
            $read = $fs.Read($buf, 0, 8)
        } finally {
            $fs.Dispose()
        }
    } catch {
        return $null
    }
    if ($read -lt 3) { return $null }

    # JPEG: FF D8 FF
    if ($buf[0] -eq 0xFF -and $buf[1] -eq 0xD8 -and $buf[2] -eq 0xFF) { return 'jpg' }
    # PNG: 89 50 4E 47 0D 0A 1A 0A
    if ($read -ge 8 -and $buf[0] -eq 0x89 -and $buf[1] -eq 0x50 -and $buf[2] -eq 0x4E -and $buf[3] -eq 0x47 `
        -and $buf[4] -eq 0x0D -and $buf[5] -eq 0x0A -and $buf[6] -eq 0x1A -and $buf[7] -eq 0x0A) { return 'png' }
    # BMP: 42 4D  ("BM")
    if ($buf[0] -eq 0x42 -and $buf[1] -eq 0x4D) { return 'bmp' }

    return $null
}

function Get-FileSha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $hash = $sha.ComputeHash($fs)
        } finally {
            $fs.Dispose()
        }
    } finally {
        $sha.Dispose()
    }
    -join ($hash | ForEach-Object { $_.ToString('x2') })
}

# ---------------------------------------------------------------------------
# Aplicacion del fondo via SystemParametersInfo (user32.dll)
# ---------------------------------------------------------------------------
function Set-Wallpaper {
    param([string]$ImagePath, [hashtable]$StyleValues)

    # Escribir estilo en el registro ANTES de aplicar.
    $deskKey = 'HKCU:\Control Panel\Desktop'
    Set-ItemProperty -Path $deskKey -Name 'WallpaperStyle' -Value $StyleValues.WallpaperStyle
    Set-ItemProperty -Path $deskKey -Name 'TileWallpaper'  -Value $StyleValues.TileWallpaper

    # P/Invoke a SystemParametersInfo. Add-Type compila contra el .NET del
    # sistema; no instala nada.
    if (-not ([System.Management.Automation.PSTypeName]'WallpaperClient.Native').Type) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace WallpaperClient {
    public static class Native {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
    }
}
'@
    }

    $SPI_SETDESKWALLPAPER = 20
    $SPIF_UPDATEINIFILE   = 0x01
    $SPIF_SENDCHANGE      = 0x02
    $flags = $SPIF_UPDATEINIFILE -bor $SPIF_SENDCHANGE

    $res = [WallpaperClient.Native]::SystemParametersInfo($SPI_SETDESKWALLPAPER, 0, $ImagePath, $flags)
    if ($res -eq 0) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "SystemParametersInfo fallo (Win32Error=$err)"
    }
}

# ===========================================================================
# INICIO
# ===========================================================================
Write-Log "----- Ejecucion iniciada (Force=$Force) -----"

# --- 1. Leer config.json -------------------------------------------------
if (-not (Test-Path $ConfigPath)) {
    Exit-With 1 "No se encontro config.json en: $ConfigPath" 'ERROR'
}
try {
    $cfg = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Exit-With 1 "config.json invalido: $($_.Exception.Message)" 'ERROR'
}

$serverUrl      = [string]$cfg.serverUrl
$style          = if ($cfg.style) { [string]$cfg.style } else { 'fill' }
$maxSizeMB      = if ($cfg.maxSizeMB)      { [double]$cfg.maxSizeMB }      else { 20 }
$timeoutSeconds = if ($cfg.timeoutSeconds) { [int]$cfg.timeoutSeconds }    else { 30 }

if ([string]::IsNullOrWhiteSpace($serverUrl)) {
    Exit-With 1 "config.json: serverUrl vacio" 'ERROR'
}

$styleValues = Get-StyleRegistryValues $style
if ($null -eq $styleValues) {
    Exit-With 1 "config.json: style '$style' no reconocido (use fill|fit|stretch|center|tile|span)" 'ERROR'
}

# --- 2. Consultar al servidor (TLS 1.2) ----------------------------------
# Solo se acepta https para el endpoint del servidor.
if ($serverUrl -notmatch '^https://') {
    Exit-With 1 "serverUrl debe ser https://  (recibido: $serverUrl)" 'ERROR'
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    # En .NET viejos puede no existir el enum; intentamos por valor numerico.
    try { [Net.ServicePointManager]::SecurityProtocol = 3072 } catch {}
}

try {
    $resp = Invoke-RestMethod -Uri $serverUrl -Method Get -TimeoutSec $timeoutSeconds -UseBasicParsing
} catch {
    Exit-With 2 "Error consultando el servidor: $($_.Exception.Message)" 'ERROR'
}

if ($null -eq $resp -or -not $resp.version -or -not $resp.url) {
    Exit-With 2 "Respuesta del servidor invalida (falta 'version' o 'url')" 'ERROR'
}

$remoteVersion = [string]$resp.version
$imageUrl      = [string]$resp.url
$remoteSha     = if ($resp.PSObject.Properties['sha256']) { [string]$resp.sha256 } else { $null }

# La URL de la imagen tambien debe ser https.
if ($imageUrl -notmatch '^https://') {
    Exit-With 2 "La URL de imagen debe ser https:// (recibido: $imageUrl)" 'ERROR'
}

Write-Log "Servidor OK. version=$remoteVersion url=$imageUrl sha256=$([bool]$remoteSha)"

# --- 3. Comparar con el estado guardado ----------------------------------
$currentVersion = $null
if (Test-Path $StateFile) {
    try {
        $state = Get-Content -Path $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $currentVersion = [string]$state.version
    } catch {
        Write-Log "state.json ilegible, se ignora: $($_.Exception.Message)" 'WARN'
    }
}

if ((-not $Force) -and $currentVersion -and ($currentVersion -eq $remoteVersion)) {
    Exit-With 0 "Sin cambios (version=$remoteVersion). Nada que hacer."
}

# --- 4. Descargar a temporal y validar -----------------------------------
if (-not (Test-Path $ImageDir)) {
    New-Item -ItemType Directory -Path $ImageDir -Force | Out-Null
}
$tempFile = Join-Path $ImageDir ("download_" + [Guid]::NewGuid().ToString('N') + '.tmp')

try {
    # Invoke-WebRequest usa la misma pila TLS ya configurada.
    Invoke-WebRequest -Uri $imageUrl -OutFile $tempFile -TimeoutSec $timeoutSeconds -UseBasicParsing
} catch {
    if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
    Exit-With 2 "Error descargando la imagen: $($_.Exception.Message)" 'ERROR'
}

try {
    # 4a. Tamano maximo
    $sizeBytes = (Get-Item $tempFile).Length
    $maxBytes  = [long]($maxSizeMB * 1MB)
    if ($sizeBytes -le 0) {
        throw "La imagen descargada esta vacia"
    }
    if ($sizeBytes -gt $maxBytes) {
        throw ("La imagen ({0:N0} bytes) supera el maximo configurado ({1:N0} bytes = {2} MB)" -f $sizeBytes, $maxBytes, $maxSizeMB)
    }

    # 4b. Bytes magicos
    $kind = Test-ImageMagic $tempFile
    if ($null -eq $kind) {
        throw "La imagen no es JPG, PNG ni BMP (firma de archivo no reconocida)"
    }

    # 4c. sha256 (si el servidor lo envio)
    if ($remoteSha) {
        $localSha = Get-FileSha256 $tempFile
        if ($localSha -ne $remoteSha.ToLowerInvariant()) {
            throw "sha256 no coincide (esperado=$remoteSha, obtenido=$localSha)"
        }
    }
} catch {
    if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
    Exit-With 3 "Imagen rechazada: $($_.Exception.Message)" 'ERROR'
}

Write-Log "Imagen valida (tipo=$kind, bytes=$sizeBytes)"

# --- 5. Mover a ubicacion final (atomico) y aplicar ----------------------
$finalFile = Join-Path $ImageDir ("wallpaper." + $kind)
try {
    if (Test-Path $finalFile) {
        # Move atomico sobre el mismo volumen; -Force reemplaza.
        Move-Item -Path $tempFile -Destination $finalFile -Force
    } else {
        Move-Item -Path $tempFile -Destination $finalFile
    }
} catch {
    if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
    Exit-With 4 "No se pudo mover la imagen a su ubicacion final: $($_.Exception.Message)" 'ERROR'
}

try {
    Set-Wallpaper -ImagePath $finalFile -StyleValues $styleValues
} catch {
    Exit-With 4 "No se pudo aplicar el fondo: $($_.Exception.Message)" 'ERROR'
}

Write-Log "Fondo aplicado correctamente (estilo=$style)"

# --- 6. Guardar la nueva version solo si todo salio bien -----------------
try {
    $newState = [ordered]@{
        version   = $remoteVersion
        appliedAt = (Get-Date).ToString('o')
        imagePath = $finalFile
        style     = $style
    }
    ($newState | ConvertTo-Json) | Set-Content -Path $StateFile -Encoding UTF8
} catch {
    Write-Log "Fondo aplicado pero no se pudo guardar el estado: $($_.Exception.Message)" 'WARN'
}

Exit-With 0 "Listo. Nueva version aplicada: $remoteVersion"
