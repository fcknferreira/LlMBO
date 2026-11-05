#!/bin/bash
# Duplo clique: compila o LlMBO, instala em /Applications e abre. Saída em build.log.
cd "$(dirname "$0")"
{
  ./build.sh || exit 1
  pkill -x LlMBO 2>/dev/null; sleep 1
  rm -rf /Applications/LlMBO.app
  ditto build/LlMBO.app /Applications/LlMBO.app
  xattr -cr /Applications/LlMBO.app; codesign --force --deep --sign - /Applications/LlMBO.app
  open /Applications/LlMBO.app && echo "INSTALADO em /Applications/LlMBO.app"
} > build.log 2>&1
echo "EXIT=$?" >> build.log
tail -5 build.log
