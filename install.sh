#!/bin/bash
# Instala (ou atualiza) o LlMBO a partir da última Release do GitHub.
#   curl -fsSL https://raw.githubusercontent.com/fcknferreira/LlMBO/main/install.sh | bash
# Arquivo baixado pelo curl não recebe a marca de quarentena, então o app abre sem o aviso do macOS.
# Mesmo assim, o pacote só é instalado se tiver a assinatura das Releases do LlMBO.
set -euo pipefail
REPO="fcknferreira/LlMBO"
LEAF="9e652604d46ed9ddec648e1beeb56bf92d869d77"
DEST="/Applications/LlMBO.app"

[ "$(uname)" = Darwin ] || { echo "O LlMBO é só para macOS."; exit 1; }
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 13 ] || { echo "O LlMBO precisa do macOS 13 ou mais novo."; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "Baixando o LlMBO…"
curl -fL --progress-bar "https://github.com/$REPO/releases/latest/download/LlMBO.zip" -o "$TMP/LlMBO.zip"
ditto -x -k "$TMP/LlMBO.zip" "$TMP/out"
APP="$TMP/out/LlMBO.app"
codesign --verify --deep --strict -R "=identifier \"com.llmbo.app\" and certificate leaf = H\"$LEAF\"" "$APP" \
  || { echo "A assinatura do arquivo baixado não confere. Nada foi instalado."; exit 1; }

if pgrep -f "/Contents/MacOS/LlMBO$" >/dev/null; then
  echo "Fechando o LlMBO aberto…"
  osascript -e 'quit app id "com.llmbo.app"' 2>/dev/null || true
  for _ in $(seq 1 60); do pgrep -f "/Contents/MacOS/LlMBO$" >/dev/null || break; sleep 0.25; done
fi
if [ -w /Applications ]; then SUDO=""; else SUDO="sudo"; echo "Pedindo a senha para gravar em /Applications…"; fi
$SUDO rm -rf "$DEST"
$SUDO ditto "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
echo "Instalado em $DEST. Abrindo…"
open "$DEST"
