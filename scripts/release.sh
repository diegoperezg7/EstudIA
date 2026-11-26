#!/bin/bash
# Publica una versión: app firmada con Developer ID, DMG notarizado, appcast de Sparkle y release en GitHub.
# Uso: scripts/release.sh 1.2 [notas.md]
# Requisitos (una vez, en el Mac con el certificado; ver README, «Publicar una versión»):
#   - certificado «Developer ID Application» en el llavero
#   - xcrun notarytool store-credentials estudia
#   - clave de Sparkle en el llavero y su parte pública en Resources/sparkle-public-key.txt
#   - gh auth login con la cuenta dueña del repo
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?Uso: scripts/release.sh <versión> [notas.md]}"
NOTES="${2:-}"
REPO="diegoperezg7/EstudIA"
PROFILE="${NOTARY_PROFILE:-estudia}"

security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || { echo "Falta el certificado Developer ID Application en el llavero."; exit 1; }
[ -s Resources/sparkle-public-key.txt ] || { echo "Falta Resources/sparkle-public-key.txt (generate_keys -p)."; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "Hay cambios sin commitear."; exit 1; }

STUDYAI_VERSION="$VERSION" scripts/build-app.sh
scripts/make-dmg.sh
ID=$(security find-identity -v -p codesigning | awk '/Developer ID Application/{print $2; exit}')
codesign --force --timestamp --sign "$ID" build/EstudIA.dmg

echo "Notarizando (unos minutos)…"
xcrun notarytool submit build/EstudIA.dmg --keychain-profile "$PROFILE" --wait
xcrun stapler staple build/EstudIA.dmg
spctl -a -t open --context context:primary-signature -v build/EstudIA.dmg

# Una carpeta por versión: generate_appcast firma todo lo que encuentre en ella.
OUT="build/release-$VERSION"
mkdir -p "$OUT"
cp build/EstudIA.dmg "$OUT/EstudIA-$VERSION.dmg"
# Firma EdDSA con la clave privada del llavero y appcast.xml apuntando a esta release.
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" "$OUT"

git tag -a "v$VERSION" -m "EstudIA $VERSION"
git push origin "v$VERSION"
if [ -n "$NOTES" ]; then NOTE_ARGS=(--notes-file "$NOTES"); else NOTE_ARGS=(--generate-notes); fi
gh release create "v$VERSION" "$OUT/EstudIA-$VERSION.dmg" "$OUT/appcast.xml" \
  --repo "$REPO" --title "EstudIA $VERSION" "${NOTE_ARGS[@]}"
echo "Publicada v$VERSION. Las apps instaladas la verán en su próxima comprobación diaria (o con «Buscar actualizaciones…»)."
