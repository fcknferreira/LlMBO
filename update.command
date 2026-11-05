#!/bin/bash
# Atualiza o LlMBO sem soltar o Mac: compila, deixa o aviso de troca, fecha o app (que sai segurando o repouso),
# instala a versão nova e abre (que assume o Mac de onde a outra parou). Serve com a tampa fechada e agentes
# trabalhando. Se a versão nova não abrir, o vigia devolve o repouso em até ~80 s. Saída em update.log.
cd "$(dirname "$0")"
SUPPORT="$HOME/Library/Application Support/LlMBO"
{
  ./build.sh || { echo "Compilação falhou: o app em uso não foi tocado."; exit 1; }
  echo pending > "$SUPPORT/update-handoff"
  # Fecha só o app (não os servidores MCP, que também se chamam LlMBO).
  osascript -e 'quit app id "com.llmbo.app"' 2>/dev/null
  # Espera o app sair de verdade antes de trocar o pacote: com 5 s ele às vezes ainda estava saindo, o pacote
  # sumia por baixo dele e o `open` falhava com -600 (03/11/2026). Se não sair em 15 s, SIGTERM (que também
  # respeita o aviso de troca) e mais 5 s.
  APP="/Applications/LlMBO.app/Contents/MacOS/LlMBO$"
  running() { pgrep -f "$APP" >/dev/null; }
  for _ in $(seq 1 60); do running || break; sleep 0.25; done
  if running; then echo "$(date +%T) o app não saiu em 15 s; mandando SIGTERM"; pkill -TERM -f "$APP"
    for _ in $(seq 1 20); do running || break; sleep 0.25; done; fi
  running && { echo "O app em uso não saiu: nada foi trocado."; rm -f "$SUPPORT/update-handoff"; exit 1; }
  echo "$(date +%T) app fechado"
  rm -rf /Applications/LlMBO.app
  ditto build/LlMBO.app /Applications/LlMBO.app
  xattr -cr /Applications/LlMBO.app
  # O LaunchServices pode ainda lembrar do processo que acabou de sair; tenta de novo antes de desistir.
  for i in 1 2 3; do
    open /Applications/LlMBO.app && { echo "ATUALIZADO: /Applications/LlMBO.app"; break; }
    echo "$(date +%T) open falhou (tentativa $i)"; sleep 2
  done
  echo "Repouso desligado agora: $(pmset -g | awk '/SleepDisabled/ {print $2}')"
} > update.log 2>&1
echo "EXIT=$?" >> update.log
tail -4 update.log
