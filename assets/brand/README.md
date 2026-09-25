# Arveil app icons / Iconos de Arveil

An ivory ribbon forms an open **A** on pine green (`#245B51`, the client's
theme seed). The shaded raster artwork is used on macOS and older Android
launchers; a simplified vector silhouette supports adaptive and themed icons.

## Assets

| File | Purpose |
| --- | --- |
| `icon-square-source.png` | Opaque square master, 1254 × 1254 px |
| `icon-macos-source.png` | macOS master with rounded tile and transparent margins, 1254 × 1254 px |
| `mark.svg` | Flat ivory vector silhouette, transparent background |
| `preview.html` | Local preview of real assets at small sizes and with launcher masks |
| `prompts.json` | Generation prompts and provenance |

The two raster masters were generated with the built-in `image_gen` tool.
The vector is a simplified native adaptation of that silhouette. Sources and
exports are covered by the repository's [Apache-2.0 license](../../LICENSE).
The export command needs no image-generation service, API key or paid account.

## Regenerate / Regenerar

On macOS with Python 3, from the repository root:

```sh
python3 scripts/export_app_icons.py
open assets/brand/preview.html
```

The script uses the macOS `sips` and `iconutil` tools. It writes:

- **macOS:** all 10 catalog slots (7 PNG sizes, 16–1024 px), preserving the
  existing `AppIcon.appiconset` filenames and Xcode configuration.
- **Android 7:** legacy launchers at 48, 72, 96, 144 and 192 px.
- **Android 8+:** separate pine-green background and vector foreground, with
  the silhouette scaled inside the circular 66 dp safe zone on a 108 dp layer.
- **Android 13+:** the same vector as a monochrome layer for launchers that
  support themed icons. The launcher supplies its theme colors.
- **Extras:** `dist/brand/Arveil.icns`, `arveil-512.png` and `arveil-1024.png`.
  These convenience exports are ignored by Git; the 1024 px opaque square can
  serve as a starting point for future platforms. There is no iOS target yet.

Generated platform resources are committed, so normal builds on Linux or macOS
**do not need to run this script**. Re-run it only after changing the sources.
Review and commit source and generated-resource changes together. PNG encoder
output can vary across macOS versions; review rendered pixels and dimensions.
Package a new app version to distribute icon changes; existing ZIP/APK files
and release drafts are not modified by this command.

**Español:** las fuentes editables y los originales están aquí; los iconos que
consume cada plataforma están en el cliente Flutter. Para regenerarlos ejecuta
el comando anterior en macOS. Para compilar o instalar la app no hace falta
regenerarlos. La vista previa permite revisar tamaños pequeños, fondos claros
y oscuros y los recortes circular y cuadrado redondeado de Android. El icono
monocromo adopta los colores que elija el launcher. Los paquetes ya creados
conservan su icono anterior hasta preparar una nueva versión.

## Platform references

- [Android adaptive icons](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive)
- [Xcode app icon configuration](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)
- [Apple app icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons)
