<#
.SYNOPSIS
    Desinstala el cliente de wallpaper.

.DESCRIPTION
    - Quita la Tarea Programada.
    - Borra C:\ProgramData\WallpaperClient.
    - Opcionalmente, con -RemoveUserState, borra tambien el estado por usuario
      (%LOCALAPPDATA%\WallpaperClient) del usuario que ejecuta este script.

    Debe ejecutarse como Administrador.

.PARAMETER RemoveUserState
    Si se indica, elimina ademas la carpeta de estado/log/imagenes del usuario
    actual (%LOCALAPPDATA%\WallpaperClient). Nota: solo afecta al usuario que
    corre el script; el estado de otros usuarios vive en sus propios perfiles.
#>

[CmdletBinding()]
param(
    [string]$TaskName = 'WallpaperClient',
    [switch]$RemoveUserState
)

$ErrorActionPreference = 'Stop'

# Exigir administrador
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Este script debe ejecutarse como Administrador." -ForegroundColor Red
    exit 1
}

# 1. Quitar la tarea
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Tarea '$TaskName' eliminada." -ForegroundColor Green
} else {
    Write-Host "La tarea '$TaskName' no existia." -ForegroundColor Yellow
}

# 2. Borrar la carpeta de instalacion
$InstallDir = Join-Path $env:ProgramData 'WallpaperClient'
if (Test-Path $InstallDir) {
    Remove-Item -Path $InstallDir -Recurse -Force
    Write-Host "Carpeta de instalacion eliminada: $InstallDir" -ForegroundColor Green
} else {
    Write-Host "No existia la carpeta de instalacion: $InstallDir" -ForegroundColor Yellow
}

# 3. Estado por usuario (opcional)
if ($RemoveUserState) {
    $StateDir = Join-Path $env:LOCALAPPDATA 'WallpaperClient'
    if (Test-Path $StateDir) {
        Remove-Item -Path $StateDir -Recurse -Force
        Write-Host "Estado del usuario actual eliminado: $StateDir" -ForegroundColor Green
    } else {
        Write-Host "No existia estado para el usuario actual: $StateDir" -ForegroundColor Yellow
    }
    Write-Host "NOTA: el estado de OTROS usuarios permanece en sus perfiles" -ForegroundColor Yellow
    Write-Host "      (%LOCALAPPDATA%\WallpaperClient de cada uno)." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Desinstalacion completada." -ForegroundColor Green
