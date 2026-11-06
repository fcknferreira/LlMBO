#!/bin/bash
# Compila o LlMBO e monta o LlMBO.app em ./build
set -euo pipefail
cd "$(dirname "$0")"

# UNIVERSAL=1 (release.sh): binário para Apple Silicon e Intel.
if [ "${UNIVERSAL:-0}" = 1 ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/out/Products/Release/LlMBO
else
  swift build -c release
  BIN=.build/release/LlMBO
fi
WIDGET_BIN="$(dirname "$BIN")/LlMBOWidget"

# Monta o .app fora do iCloud: o iCloud adiciona atributos que quebram a assinatura.
STAGE="$(mktemp -d)"
APP="$STAGE/LlMBO.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/llmbo-signal "$APP/Contents/Resources/"
# Vigia contra travamento: registrado pelo app com SMAppService.agent (Watchdog.swift)
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp Resources/com.llmbo.app.watchdog.plist "$APP/Contents/Library/LaunchAgents/"
cp Resources/AppIcon.png Resources/AppIconLight.png "$APP/Contents/Resources/"
cp -R Resources/*.lproj Resources/Fonts "$APP/Contents/Resources/"
# Sons do aviso (Design/render_sounds.swift): soltos em Resources, onde o NSSound e o UNNotificationSound acham pelo nome
cp Resources/Sounds/*.aiff "$APP/Contents/Resources/"
cp Resources/SocialIcons/*.svg "$APP/Contents/Resources/"

# Widgets (Sources/LlMBOWidget): extensão em PlugIns, com textos e fonte próprios (o widget não lê o pacote do app).
APPEX="$APP/Contents/PlugIns/LlMBOWidget.appex"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
cp "$WIDGET_BIN" "$APPEX/Contents/MacOS/LlMBOWidget"
cp Resources/Widget-Info.plist "$APPEX/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy
for k in CFBundleShortVersionString CFBundleVersion; do
  "$PB" -c "Set :$k $("$PB" -c "Print :$k" Resources/Info.plist)" "$APPEX/Contents/Info.plist"
done
SDKV="$(xcrun --show-sdk-version 2>/dev/null || sw_vers -productVersion)"
for kv in "DTPlatformName macosx" "DTSDKName macosx$SDKV" "DTPlatformVersion $SDKV"; do
  "$PB" -c "Add :${kv%% *} string ${kv#* }" "$APPEX/Contents/Info.plist"
done
cp -R Resources/*.lproj Resources/Fonts "$APPEX/Contents/Resources/"

# Ícone: gera o .icns a partir do PNG de 1024 px
ICONSET="$STAGE/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
chmod +x "$APP/Contents/Resources/llmbo-signal"
xattr -cr "$APP"
# Assina com o certificado próprio "LlMBO Local Signing" do chaveiro, se existir: a identidade fica a mesma
# entre builds e o macOS mantém as permissões (gravação de áudio do sistema, etc.). Sem ele, ad-hoc —
# e cada build vira um app novo para essas permissões.
IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk -F'"' '/"LlMBO Local Signing"/ {split($1, a, " "); print a[2]; exit}')"
# Widget primeiro, com as próprias permissões (sandbox + leitura da pasta do LlMBO); depois o app sem --deep,
# que assinaria a extensão de novo sem elas.
codesign --force --sign "${IDENTITY:--}" --options runtime --entitlements Resources/Widget.entitlements "$APPEX"
codesign --force --sign "${IDENTITY:--}" "$APP"
codesign --verify --deep --strict "$APP"
if [ -n "$IDENTITY" ]; then echo "Assinatura: LlMBO Local Signing ($IDENTITY)"; else echo "Assinatura: ad-hoc"; fi
rm -rf build/LlMBO.app; mkdir -p build
ditto "$APP" build/LlMBO.app

echo "Pronto: build/LlMBO.app"
echo "Para instalar: duplo clique em build.command"
