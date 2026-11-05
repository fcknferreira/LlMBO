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
# O site fica fora do repositório (~/Downloads/website LLMBO); se estiver lá, atualiza a versão mostrada nele.
SITE="${LLMBO_SITE:-$HOME/Downloads/website LLMBO}"
[ -f "$SITE/site.js" ] && sed -i '' "s/^  version: \".*\",/  version: \"$VERSION\",/" "$SITE/site.js"
echo "Versão $VERSION ($BUILD)"

UNIVERSAL=1 ./build.sh
APP=build/LlMBO.app
codesign --verify --deep --strict -R "=identifier \"com.llmbo.app\" and certificate leaf = H\"$LEAF\"" "$APP" || {
  echo "O app não está assinado com o certificado \"LlMBO Local Signing\" ($LEAF)."
  echo "Sem ele a atualização pelo app recusaria esta versão. Nada foi gerado."; exit 1; }
lipo -archs "$APP/Contents/MacOS/LlMBO"

rm -rf dist; mkdir -p dist
ditto -c -k --keepParent "$APP" dist/LlMBO.zip

Design/make_dmg.sh "$APP" dist/LlMBO.dmg
ls -lh dist

if [ "$PUBLISH" = "--publish" ]; then
  command -v gh >/dev/null || { echo "Instale e entre no gh (brew install gh && gh auth login)."; exit 1; }
  NOTES=(); [ -f dist/notes.md ] && NOTES=(--notes-file dist/notes.md)
  gh release create "v$VERSION" dist/LlMBO.zip dist/LlMBO.dmg --repo "$REPO" --title "LlMBO $VERSION" "${NOTES[@]}"
  echo "Publicado: https://github.com/$REPO/releases/tag/v$VERSION"
else
  echo "Arquivos em dist/. Para publicar: ./release.sh $VERSION --publish"
fi
