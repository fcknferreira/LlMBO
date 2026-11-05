#!/bin/bash
# Teste guiado de "Religar ao abrir a tampa": espera você desligar o LlMBO (clique no ícone), fechar a tampa e abrir,
# e mede quanto tempo depois de abrir ele volta ligado. Registro em lidtest/rearmtest.log.
S="$HOME/Library/Application Support/LlMBO"; OUT="$S/lidtest"; mkdir -p "$OUT"; LOG="$OUT/rearmtest.log"; : > "$LOG"
log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }
lid() { ioreg -r -k AppleClamshellState -d 4 | awk '/AppleClamshellState/ {print ($NF=="Yes") ? "fechada" : "aberta"; exit}'; }
armed() { [ "$(cat "$S/armed" 2>/dev/null)" = 1 ] && echo ligado || echo desligado; }
wait_for() {  # descrição, condição; até 10 min
  log "PASSO: $1"
  for _ in $(seq 1 600); do eval "$2" && { log "ok: $1 — tampa=$(lid) llmbo=$(armed)"; return 0; }; sleep 1; done
  log "desisti de esperar: $1"; exit 1
}
log "início — tampa=$(lid) llmbo=$(armed) religar_ao_abrir=$(defaults read com.llmbo.app armOnLidOpen 2>/dev/null || echo padrão-ligado)"
wait_for "1. desligue o LlMBO (clique esquerdo no ícone)" '[ "$(armed)" = desligado ]'
wait_for "2. feche a tampa" '[ "$(lid)" = fechada ]'
wait_for "3. abra a tampa" '[ "$(lid)" = aberta ]'
T0=$(date +%s)
for _ in $(seq 1 60); do [ "$(armed)" = ligado ] && break; sleep 0.5; done
if [ "$(armed)" = ligado ]; then log "RESULTADO: religou $(( $(date +%s) - T0 )) s depois de abrir a tampa"
else log "RESULTADO: NÃO religou em 30 s (llmbo=$(armed))"; fi
pmset -g log | awk -v s="$(date -r $((T0-900)) '+%Y-%m-%d %H:%M:%S')" '$0 >= s' | grep -E "Entering Sleep|Wake from|DarkWake to FullWake" | cut -c1-120 >> "$LOG"
log "fim"
