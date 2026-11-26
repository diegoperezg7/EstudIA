#!/bin/bash
# Compila en release, monta EstudIA.app y la firma.
# Firmar con una identidad estable mantiene el permiso de grabación entre compilaciones.
# Otra identidad: STUDYAI_SIGN_IDENTITY="..." scripts/build-app.sh
# Versión: STUDYAI_VERSION=1.2 scripts/build-app.sh (el número de build sale de la versión: 1.2 → 10200).
# Clave pública de Sparkle: Resources/sparkle-public-key.txt o SPARKLE_PUBLIC_KEY. Sin ella la app no busca actualizaciones.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64

APP=build/EstudIA.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN="$(swift build -c release --arch arm64 --show-bin-path)"
cp "$BIN/StudyAI" "$APP/Contents/MacOS/"
cp "$BIN/EstudIAMCP" "$APP/Contents/MacOS/estudia-mcp" # servidor MCP para ChatGPT/Claude
# Complemento local para ChatGPT (marketplace en carpeta), con su propia copia del servidor.
cp -R Resources/ChatGPTPlugin "$APP/Contents/Resources/ChatGPTPlugin"
mkdir -p "$APP/Contents/Resources/ChatGPTPlugin/plugins/estudia/bin" # git no guarda carpetas vacías
cp "$BIN/EstudIAMCP" "$APP/Contents/Resources/ChatGPTPlugin/plugins/estudia/bin/estudia-mcp"
cp Resources/Info.plist "$APP/Contents/"
PLIST="$APP/Contents/Info.plist"
if [ -n "${STUDYAI_VERSION:-}" ]; then
  IFS=. read -r MA MI PA <<<"$STUDYAI_VERSION"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $STUDYAI_VERSION" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((MA * 10000 + ${MI:-0} * 100 + ${PA:-0}))" "$PLIST"
fi
KEY="${SPARKLE_PUBLIC_KEY:-$(cat Resources/sparkle-public-key.txt 2>/dev/null || true)}"
[ -n "$KEY" ] && /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $KEY" "$PLIST"

# Sparkle: el framework va en Contents/Frameworks y el ejecutable lo busca ahí.
mkdir -p "$APP/Contents/Frameworks"
cp -R "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/StudyAI" 2>/dev/null || true
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Color de acento (selección de listas, controles) con la paleta del logo.
xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --accent-color AccentColor \
  --output-partial-info-plist /dev/null >/dev/null

# Developer ID si está (la que vale para repartir y notarizar); si no, Apple Development; si no, ad hoc.
# Por hash: el nombre puede venir con acentos escapados.
IDENTITIES=$(security find-identity -v -p codesigning)
IDENTITY="${STUDYAI_SIGN_IDENTITY:-$(awk '/Developer ID Application/{print $2; exit}' <<<"$IDENTITIES")}"
IDENTITY="${IDENTITY:-$(awk '/Apple Development/{print $2; exit}' <<<"$IDENTITIES")}"
SIGN=(codesign --force --options runtime --timestamp --sign "${IDENTITY:--}")
[ -z "$IDENTITY" ] && SIGN=(codesign --force --options runtime --sign -)
# Sparkle de dentro afuera, como indica su documentación.
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SP/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SP/Autoupdate"
"${SIGN[@]}" "$SP/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$APP/Contents/MacOS/estudia-mcp"
"${SIGN[@]}" "$APP/Contents/Resources/ChatGPTPlugin/plugins/estudia/bin/estudia-mcp"
"${SIGN[@]}" "$APP"
echo "OK: $APP (firma: ${IDENTITY:-ad hoc})"
