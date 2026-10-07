# Carpeta de fondos

Coloque aquí la imagen que quiere publicar como fondo de escritorio.

- El archivo por defecto es `wallpaper.jpg` (configurable en `../config.json`,
  campo `imagePath`).
- Formatos aceptados por el cliente: **JPG, PNG o BMP**.
- **Para cambiar el fondo de todos los equipos:** reemplace este archivo. El
  servidor recalcula la versión y el sha256 a partir del contenido, y los
  clientes detectan el cambio en su siguiente comprobación.

> Esta carpeta se versiona vacía (solo este archivo). La imagen real no se sube
> a git por defecto; colóquela directamente en el servidor.
