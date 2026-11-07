#!/bin/bash
# Monta o DMG de arrastar a partir de um LlMBO.app pronto (usado pelo release.sh; serve também para refazer só
# o DMG de uma versão já publicada, sem recompilar).   Design/make_dmg.sh <LlMBO.app> <saída.dmg>
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$1"; OUT="$2"
# DMG de arrastar: app, atalho para Aplicativos, o aviso "Read me · Leia antes de abrir" e o fundo com os passos
# (Design/render_dmg.swift). O Finder grava a arrumação da janela no .DS_Store do volume.
STAGE="$(mktemp -d)"; trap 'hdiutil detach "/Volumes/LlMBO" -quiet 2>/dev/null || true; rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/LlMBO/.background"
ditto "$APP" "$STAGE/LlMBO/LlMBO.app"
ln -s /Applications "$STAGE/LlMBO/Applications"
cp "Resources/DMG/Leia antes de abrir.txt" "$STAGE/LlMBO/Read me · Leia antes de abrir.txt"
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
    -- 660 × 500: ~32 pt de título e ~28 pt da barra de caminho deixam os 440 pt do fundo à vista (medido 06/11/2026).
    set the bounds of container window to {200, 120, 860, 620}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set text size of opts to 12
    set background picture of opts to file ".background:background.tiff"
    set position of item "LlMBO.app" of container window to {150, 140}
    set position of item "Applications" of container window to {390, 140}
    set position of item "Read me · Leia antes de abrir.txt" of container window to {560, 140}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
sync
hdiutil detach /Volumes/LlMBO -quiet
rm -f "$OUT"
hdiutil convert "$STAGE/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
codesign --force --sign "LlMBO Local Signing" "$OUT" 2>/dev/null || true
