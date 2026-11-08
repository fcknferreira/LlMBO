#!/bin/bash
# Gera uma versão pública do LlMBO: compila universal (Apple Silicon + Intel), assina com o certificado das
# Releases, e monta dist/LlMBO.zip (usado pela atualização do app e pelo install.sh) e dist/LlMBO.dmg.
#   ./release.sh 0.2               → só gera os arquivos em dist/ (confira antes de publicar)
#   ./release.sh 0.2 --prerelease  → publica como pré-lançamento: o app e o install.sh só olham a "latest",
#                                    então ninguém recebe; serve para testar a atualização real antes
#   ./release.sh 0.2 --promote     → (sem compilar) torna o pré-lançamento a versão de todos
#   ./release.sh 0.2 --publish     → publica direto para todos
# As notas da Release vêm de dist/notes.md, se existir (senão o gh abre o editor).
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:?uso: ./release.sh <versão> [--prerelease|--promote|--publish]}"
PUBLISH="${2:-}"
REPO="fcknferreira/LlMBO"

if [ "$PUBLISH" = "--promote" ]; then
  gh release edit "v$VERSION" --repo "$REPO" --prerelease=false --latest
  echo "v$VERSION agora é a versão de todos: https://github.com/$REPO/releases/tag/v$VERSION"
  exit 0
fi
LEAF="9e652604d46ed9ddec648e1beeb56bf92d869d77"
# Novidades do menu (WhatsNew.swift): toda versão publicada precisa da sua entrada.
grep -q "(\"$VERSION\", \[" Sources/LlMBO/WhatsNew.swift || {
  echo "Falta a entrada da versão $VERSION em Sources/LlMBO/WhatsNew.swift (novidades do menu)."; exit 1; }
# Tabela de agentes do site: o site lê o agents.json (tabela e textos) e o agent-icons.json (logos, gerado de
# Design/agent-icons/) da tag desta versão. Aqui eles são conferidos e gerados (antes de mexer em qualquer coisa)
# e, com o site nesta máquina, copiados para o site.js e o agent-icons.js como reserva.
# O site fica fora do repositório (~/Downloads/website LLMBO).
SITE="${LLMBO_SITE:-$HOME/Downloads/website LLMBO}"
python3 -I Design/agents_matrix.py agents.json "$SITE"
PLIST=Resources/Info.plist

# Versão: CFBundleShortVersionString = a escolhida; CFBundleVersion sobe um.
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"
# Se o site estiver nesta máquina, atualiza a versão de reserva mostrada nele.
[ -f "$SITE/site.js" ] && sed -i '' "s/^  version: \".*\",/  version: \"$VERSION\",/" "$SITE/site.js"
# O zip que vai para a hospedagem (~/Downloads/llmbo-site.zip) é remontado com a versão nova.
[ -x "$SITE/make_zip.sh" ] && "$SITE/make_zip.sh"
echo "Versão $VERSION ($BUILD)"

UNIVERSAL=1 ./build.sh
APP=build/LlMBO.app
codesign --verify --deep --strict -R "=identifier \"com.llmbo.app\" and certificate leaf = H\"$LEAF\"" "$APP" || {
  echo "O app não está assinado com o certificado \"LlMBO Local Signing\" ($LEAF)."
  echo "Sem ele a atualização pelo app recusaria esta versão. Nada foi gerado."; exit 1; }
lipo -archs "$APP/Contents/MacOS/LlMBO"

# As notas sobrevivem à limpeza de dist/.
NOTES_TEXT=""; [ -f dist/notes.md ] && NOTES_TEXT="$(cat dist/notes.md)"
rm -rf dist; mkdir -p dist
[ -n "$NOTES_TEXT" ] && printf '%s\n' "$NOTES_TEXT" > dist/notes.md
ditto -c -k --keepParent "$APP" dist/LlMBO.zip

Design/make_dmg.sh "$APP" dist/LlMBO.dmg
ls -lh dist

if [ "$PUBLISH" = "--publish" ] || [ "$PUBLISH" = "--prerelease" ]; then
  command -v gh >/dev/null || { echo "Instale e entre no gh (brew install gh && gh auth login)."; exit 1; }
  # O site lê a tabela, os textos e os logos da tag: sem commit, a tag sairia sem eles.
  if [ -n "$(git status --porcelain -- agents.json agent-icons.json Design/agent-icons)" ]; then
    echo "agents.json, agent-icons.json ou Design/agent-icons/ têm mudanças sem commit. Faça o commit da versão antes de publicar."
    exit 1
  fi
  NOTES=(); [ -f dist/notes.md ] && NOTES=(--notes-file dist/notes.md)
  PRE=(); [ "$PUBLISH" = "--prerelease" ] && PRE=(--prerelease)
  gh release create "v$VERSION" dist/LlMBO.zip dist/LlMBO.dmg --repo "$REPO" --title "LlMBO $VERSION" \
    ${PRE[@]+"${PRE[@]}"} ${NOTES[@]+"${NOTES[@]}"}
  echo "Publicado: https://github.com/$REPO/releases/tag/v$VERSION"
  if [ "$PUBLISH" = "--prerelease" ]; then
    echo "Pré-lançamento: ninguém recebe sozinho. Para atualizar este Mac pelo caminho real (a partir da versão instalada):"
    echo "  osascript -e 'quit app id \"com.llmbo.app\"'; sleep 3; open --env LLMBO_UPDATE_API=https://api.github.com/repos/$REPO/releases/tags/v$VERSION --env LLMBO_TEST_UPDATE=1 /Applications/LlMBO.app"
    echo "Depois de um ou dois dias sem problema: ./release.sh $VERSION --promote"
  fi
else
  echo "Arquivos em dist/. Para publicar: ./release.sh $VERSION --prerelease (depois --promote)"
fi
