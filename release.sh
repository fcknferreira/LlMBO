#!/bin/bash
# Gera uma versão pública do LlMBO: compila universal (Apple Silicon + Intel), assina com o certificado das
# Releases, e monta dist/LlMBO.zip (usado pela atualização do app e pelo install.sh) e dist/LlMBO.dmg.
#   ./release.sh 0.2            → só gera os arquivos em dist/ (confira antes de publicar)
#   ./release.sh 0.2 --publish  → também cria a tag v0.2 e a Release no GitHub (precisa do gh logado)
# As notas da Release vêm de dist/notes.md, se existir (senão o gh abre o editor).
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:?uso: ./release.sh <versão> [--publish]}"
PUBLISH="${2:-}"
REPO="fcknferreira/LlMBO"
LEAF="9e652604d46ed9ddec648e1beeb56bf92d869d77"
PLIST=Resources/Info.plist

# Versão: CFBundleShortVersionString = a escolhida; CFBundleVersion sobe um.
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"
sed -i '' "s/^  version: \".*\",/  version: \"$VERSION\",/" website/site.js
echo "Versão $VERSION ($BUILD)"

UNIVERSAL=1 ./build.sh
APP=build/LlMBO.app
codesign --verify --deep --strict -R "=identifier \"com.llmbo.app\" and certificate leaf = H\"$LEAF\"" "$APP" || {
  echo "O app não está assinado com o certificado \"LlMBO Local Signing\" ($LEAF)."
  echo "Sem ele a atualização pelo app recusaria esta versão. Nada foi gerado."; exit 1; }
lipo -archs "$APP/Contents/MacOS/LlMBO"

rm -rf dist; mkdir -p dist
ditto -c -k --keepParent "$APP" dist/LlMBO.zip

# DMG de arrastar: app, atalho para Aplicativos, o aviso "Leia antes de abrir" e o fundo com os passos
# (Design/render_dmg.swift). O Finder grava a arrumação da janela no .DS_Store do volume.
STAGE="$(mktemp -d)"; trap 'hdiutil detach "/Volumes/LlMBO" -quiet 2>/dev/null || true; rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/LlMBO/.background"
ditto "$APP" "$STAGE/LlMBO/LlMBO.app"
ln -s /Applications "$STAGE/LlMBO/Applications"
cp "Resources/DMG/Leia antes de abrir.txt" "$STAGE/LlMBO/Leia antes de abrir · Read me.txt"
tiffutil -cathidpicheck Resources/DMG/dmg-background.png Resources/DMG/dmg-background@2x.png \
  -out "$STAGE/LlMBO/.background/background.tiff" >/dev/null
hdiutil detach /Volumes/LlMBO -quiet 2>/dev/null || true
hdiutil create -volname LlMBO -srcfolder "$STAGE/LlMBO" -fs HFS+ -format UDRW -ov "$STAGE/rw.dmg" >/dev/null
hdiutil attach "$STAGE/rw.dmg" -mountpoint /Volumes/LlMBO -noautoopen -quiet
osascript <<'OSA'
tell application "Finder"
  tell disk "LlMBO"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 588}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set text size of opts to 12
    set background picture of opts to file ".background:background.tiff"
    set position of item "LlMBO.app" of container window to {150, 140}
    set position of item "Applications" of container window to {390, 140}
    set position of item "Leia antes de abrir · Read me.txt" of container window to {560, 140}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
sync
hdiutil detach /Volumes/LlMBO -quiet
hdiutil convert "$STAGE/rw.dmg" -format UDZO -imagekey zlib-level=9 -o dist/LlMBO.dmg >/dev/null
codesign --force --sign "LlMBO Local Signing" dist/LlMBO.dmg 2>/dev/null || true
ls -lh dist

if [ "$PUBLISH" = "--publish" ]; then
  command -v gh >/dev/null || { echo "Instale e entre no gh (brew install gh && gh auth login)."; exit 1; }
  NOTES=(); [ -f dist/notes.md ] && NOTES=(--notes-file dist/notes.md)
  gh release create "v$VERSION" dist/LlMBO.zip dist/LlMBO.dmg --repo "$REPO" --title "LlMBO $VERSION" "${NOTES[@]}"
  echo "Publicado: https://github.com/$REPO/releases/tag/v$VERSION"
else
  echo "Arquivos em dist/. Para publicar: ./release.sh $VERSION --publish"
fi
