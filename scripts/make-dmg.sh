#!/bin/bash
# Empaqueta build/EstudIA.app en build/EstudIA.dmg con el fondo de Resources/dmg:
# la app a la izquierda de la flecha y Aplicaciones a la derecha, para arrastrar.
# Usa dmgbuild (escribe el .DS_Store sin abrir el Finder) en un entorno aislado dentro de build/.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d build/EstudIA.app ] || scripts/build-app.sh

VENV=build/.dmgvenv
[ -x "$VENV/bin/dmgbuild" ] || { python3 -m venv "$VENV" && "$VENV/bin/pip" -q install "dmgbuild==1.6.5"; }

# Fondo nítido en Retina: TIFF con la imagen a 1x (887x444 pt) y a 2x (la original).
BG_SRC=$(ls Resources/dmg/*.png | head -1)
WORK=build/.dmgwork
mkdir -p "$WORK"
swift scripts/dmg-background.swift "$BG_SRC" "$WORK/bg@2x.png" # pastillas bajo los nombres
sips -z 444 887 "$WORK/bg@2x.png" --out "$WORK/bg.png" >/dev/null
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/bg.tiff" >/dev/null

cat > "$WORK/settings.py" <<PY
files = ["build/EstudIA.app"]
symlinks = {"Aplicaciones": "/Applications"}
background = "$WORK/bg.tiff"
window_rect = ((200, 120), (887, 444))
icon_size = 112
text_size = 13
icon_locations = {"EstudIA.app": (270, 205), "Aplicaciones": (610, 205)}
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
format = "UDZO"
PY
rm -f build/EstudIA.dmg
"$VENV/bin/dmgbuild" -s "$WORK/settings.py" "EstudIA" build/EstudIA.dmg
echo "OK: build/EstudIA.dmg"
