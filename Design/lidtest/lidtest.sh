#!/bin/bash
# Roteiro dos testes com a tampa fechada (rodar em segundo plano: nohup Design/lidtest/lidtest.sh &).
# Segura o Mac com uma tarefa longa de teste, espera a tampa fechar e então:
#   1. tela interna apagada por trás da tampa (90 s)
#   2. fim do trabalho: aviso adiantado + som, repouso devolvido, o macOS dorme sozinho (ou o empurrão de 60 s)
#   3. volume do Mac antes/durante/depois do som
#   4. despertar agendado: acorda por completo ou "dark wake"? o LlMBO roda a tempo?
#   5. vigia: app derrubado com kill -9 segurando o Mac → repouso devolvido e Mac dorme
# Tudo vai para lidtest.log; o registro de energia do macOS (pmset -g log) é copiado no fim.
S="$HOME/Library/Application Support/LlMBO"
SIG="$S/llmbo-signal"
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$S/lidtest"; mkdir -p "$OUT"
LOG="$OUT/lidtest.log"; : > "$LOG"
DISP="$OUT/display"
swiftc -O -o "$DISP" "$DIR/display.swift" 2>/dev/null

log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }
lid() { ioreg -r -k AppleClamshellState -d 4 | awk '/AppleClamshellState/ {print ($NF=="Yes") ? "fechada" : "aberta"; exit}'; }
sd()  { pmset -g | awk '/SleepDisabled/ {print $2}'; }
app() { pgrep -f '/Applications/LlMBO.app/Contents/MacOS/LlMBO$' | head -1; }
hb()  { echo $(( $(date +%s) - $(stat -f %m "$S/heartbeat" 2>/dev/null || echo 0) )); }
held(){ [ -f "$S/holding" ] && echo sim || echo não; }
vol() { osascript -e 'output volume of (get volume settings)' 2>/dev/null; }
state() { echo "tampa=$(lid) repouso_desligado=$(sd) llmbo_segura=$(held) app=$(app) sinal_de_vida=$(hb)s $("$DISP") volume=$(vol)"; }
# Registra a cada `step` segundos por `dur` segundos; um salto no relógio = o Mac dormiu nesse meio-tempo.
watch() {  # nome dur step
  local end=$(( $(date +%s) + $2 )) last=$(date +%s)
  while [ "$(date +%s)" -lt "$end" ]; do
    local now=$(date +%s)
    [ $(( now - last )) -gt $(( $3 + 15 )) ] && log "[$1] *** relógio saltou $(( now - last )) s: o Mac dormiu ***"
    last=$now
    log "[$1] $(state)"
    sleep "$3"
  done
}
# Tarefa longa de teste: segura enquanto o processo `sleep` existir; kill solta.
start_hold() { sleep 7200 & HOLDPID=$!; "$SIG" hold --pid "$HOLDPID" --name "teste da tampa" >/dev/null 2>&1; log "tarefa de teste segurando (pid $HOLDPID)"; }
stop_hold()  { kill "$HOLDPID" 2>/dev/null; log "tarefa de teste solta"; }

START=$(date '+%Y-%m-%d %H:%M:%S')
log "início — $(state)"
start_hold
log "ESPERANDO A TAMPA FECHAR (até 15 min)"
for _ in $(seq 1 180); do [ "$(lid)" = "fechada" ] && break; sleep 5; done
[ "$(lid)" = "fechada" ] || { log "a tampa não fechou em 15 min; fim"; stop_hold; exit 1; }
log "TAMPA FECHADA"

# 1. Tela apagada por trás da tampa
watch "1-tela" 90 5

# 4 (preparo). Despertar agendado para depois do fim do trabalho dormir
WAKE_AT=$(( $(date +%s) + 300 ))
WAKE_STR=$(date -r $WAKE_AT '+%m/%d/%y %H:%M:%S')
sudo -n pmset schedule wake "$WAKE_STR" >> "$LOG" 2>&1 && log "despertar de teste agendado para $(date -r $WAKE_AT '+%H:%M:%S')"

# 2 e 3. Fim do trabalho: solta a tarefa; aviso adiantado + som, depois o repouso volta e o Mac dorme
log "VOLUME antes: $(vol)"
stop_hold
watch "2-fim" 150 1      # o script para enquanto o Mac dorme; o salto do relógio mostra quando

# 4. Depois do despertar
log "DEPOIS DO DESPERTAR — $(state)"
watch "4-despertar" 20 2
log "VOLUME depois: $(vol)"

# 5. Vigia: segura de novo, derruba o app e espera o vigia devolver o repouso e pôr o Mac para dormir
start_hold
watch "5-segura" 15 3
PID=$(app); log "derrubando o LlMBO (kill -9 $PID)"; kill -9 "$PID" 2>/dev/null
watch "5-vigia" 150 3
stop_hold

# Ao voltar (tampa aberta): reabre o app e guarda o registro de energia do macOS desde o início
for _ in $(seq 1 720); do [ "$(lid)" = "aberta" ] && break; sleep 5; done
log "TAMPA ABERTA — $(state)"
[ -z "$(app)" ] && open /Applications/LlMBO.app && log "LlMBO reaberto"
sleep 8; log "depois de reabrir — $(state)"
pmset -g log | awk -v s="$START" '$0 >= s' | grep -E "Sleep|Wake|DarkWake|Display is turned|Clamshell|Assertions" | grep -v "PreventUserIdle" > "$OUT/pmset.log"
cp "$S/watchdog.log" "$OUT/" 2>/dev/null
log "FIM"
