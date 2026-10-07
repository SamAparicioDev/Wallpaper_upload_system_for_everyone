<#
.SYNOPSIS
    Instala el cliente de wallpaper y registra la Tarea Programada.

.DESCRIPTION
    - Debe ejecutarse como Administrador.
    - Copia los archivos a C:\ProgramData\WallpaperClient.
    - Registra una tarea que se dispara al INICIAR SESION de cualquier usuario,
      se ejecuta como el usuario que inicia sesion (grupo BUILTIN\Users,
      SID S-1-5-32-545) con privilegios limitados (nunca SYSTEM), y se repite
      cada N minutos de forma indefinida.
    - El lanzamiento es sin ventana visible (wscript + .vbs -> powershell oculto).
    - Es idempotente: reinstalar actualiza sin duplicar la tarea.

.NOTES
    Windows 10/11, todas las ediciones. Solo Windows PowerShell 5.1 y
    componentes nativos. No depende de directivas de grupo.
#>

[CmdletBinding()]
param(
    [string]$TaskName = 'WallpaperClient'
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1. Exigir privilegios de administrador
# ---------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Este script debe ejecutarse como Administrador." -ForegroundColor Red
    Write-Host "Abra PowerShell con 'Ejecutar como administrador' y vuelva a intentarlo." -ForegroundColor Yellow
    exit 1
}

$SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallDir = Join-Path $env:ProgramData 'WallpaperClient'

Write-Host "Instalando WallpaperClient en: $InstallDir" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 2. Copiar archivos a C:\ProgramData\WallpaperClient
# ---------------------------------------------------------------------------
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

$filesToCopy = @('wallpaper-client.ps1', 'config.json')
foreach ($f in $filesToCopy) {
    $src = Join-Path $SourceDir $f
    if (-not (Test-Path $src)) {
        Write-Host "ERROR: No se encontro '$f' junto a install.ps1." -ForegroundColor Red
        exit 1
    }
    Copy-Item -Path $src -Destination (Join-Path $InstallDir $f) -Force
}

$ClientScript = Join-Path $InstallDir 'wallpaper-client.ps1'

# Leer el intervalo desde config.json
try {
    $cfg = Get-Content -Path (Join-Path $InstallDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $intervalMinutes = [int]$cfg.intervalMinutes
} catch {
    $intervalMinutes = 15
}
if ($intervalMinutes -lt 1) { $intervalMinutes = 15 }

# Formato ISO 8601 de duracion: PT{n}M
$repInterval = "PT{0}M" -f $intervalMinutes

Write-Host "Intervalo de repeticion: cada $intervalMinutes minuto(s)." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 3. Crear el lanzador oculto (.vbs) para que no parpadee una consola
# ---------------------------------------------------------------------------
# wscript ejecuta el .vbs sin ventana; este, a su vez, lanza powershell con
# WindowStyle Hidden. WScript.Shell.Run con bWaitOnReturn=True y intWindowStyle=0.
$VbsPath = Join-Path $InstallDir 'run-hidden.vbs'
$psArgs  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$ClientScript"""

$vbsContent = @"
' Lanzador oculto de WallpaperClient. Generado por install.ps1.
' Ejecuta powershell.exe sin ninguna ventana visible.
Dim shell
Set shell = CreateObject("WScript.Shell")
shell.Run "powershell.exe $psArgs", 0, True
Set shell = Nothing
"@
Set-Content -Path $VbsPath -Value $vbsContent -Encoding ASCII

# ---------------------------------------------------------------------------
# 4. Definir la Tarea Programada por XML
# ---------------------------------------------------------------------------
# Se define por XML para garantizar:
#   - Disparador de LOGON (cualquier usuario) con repeticion indefinida.
#     (Register-ScheduledTask no siempre permite repeticion en el trigger de
#      logon de forma fiable, por eso usamos XML.)
#   - Contexto de ejecucion: grupo BUILTIN\Users (S-1-5-32-545), de modo que
#     corre como el usuario interactivo que inicia sesion, con privilegios
#     limitados. NUNCA como SYSTEM.
#
# El comando ejecuta wscript.exe run-hidden.vbs (lanzamiento sin ventana).
$WScriptExe = Join-Path $env:WINDIR 'System32\wscript.exe'

$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Aplica el fondo de escritorio publicado por el servidor central. Se ejecuta como el usuario que inicia sesion.</Description>
    <URI>\$TaskName</URI>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <Repetition>
        <Interval>$repInterval</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <GroupId>S-1-5-32-545</GroupId>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$WScriptExe</Command>
      <Arguments>"$VbsPath"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

# ---------------------------------------------------------------------------
# 5. Registrar (idempotente: si existe, se reemplaza)
# ---------------------------------------------------------------------------
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "La tarea '$TaskName' ya existe; se actualizara." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# Register-ScheduledTask con -Xml. El grupo Users no requiere credenciales.
Register-ScheduledTask -TaskName $TaskName -Xml $taskXml -Force | Out-Null

Write-Host "Tarea '$TaskName' registrada correctamente." -ForegroundColor Green
Write-Host ""
Write-Host "Instalacion completada." -ForegroundColor Green
Write-Host " - Archivos:  $InstallDir"
Write-Host " - Tarea:     $TaskName (logon de cualquier usuario, cada $intervalMinutes min)"
Write-Host " - Ejecucion: como BUILTIN\Users (privilegios limitados), sin ventana visible."
Write-Host ""
Write-Host "Para probar ahora mismo sin esperar al proximo intervalo:" -ForegroundColor Cyan
Write-Host "   Start-ScheduledTask -TaskName $TaskName"
Write-Host "O a mano (reaplicando aunque no cambie la version):" -ForegroundColor Cyan
Write-Host "   powershell -NoProfile -ExecutionPolicy Bypass -File `"$ClientScript`" -Force"
