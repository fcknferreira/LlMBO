#!/bin/bash
# Teste do som com a tampa fechada: espera a tampa fechar, toca a Supernova a 60 % e a 100 % e registra a saída de áudio.
S="$HOME/Library/Application Support/LlMBO"; OUT="$S/lidtest"; mkdir -p "$OUT"; LOG="$OUT/soundtest.log"; : > "$LOG"
DIR="$(cd "$(dirname "$0")" && pwd)"; swiftc -O -o "$OUT/audio" "$DIR/audio.swift" 2>/dev/null
log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }
lid() { ioreg -r -k AppleClamshellState -d 4 | awk '/AppleClamshellState/ {print ($NF=="Yes") ? "fechada" : "aberta"; exit}'; }
SND=/Applications/LlMBO.app/Contents/Resources/Supernova.aiff
sleep 7200 & H=$!; "$S/llmbo-signal" hold --pid $H --name "teste do som" >/dev/null 2>&1
V=$(osascript -e 'output volume of (get volume settings)')
log "tampa=$(lid) volume=$V $("$OUT/audio") — esperando a tampa fechar"
for _ in $(seq 1 120); do [ "$(lid)" = fechada ] && break; sleep 2; done
log "tampa=$(lid) $("$OUT/audio")"; sleep 5
for level in 60 100; do
  osascript -e "set volume output volume $level"
  afplay "$SND" & P=$!; sleep 1; log "tocando a ${level}%: $("$OUT/audio")"; wait $P; sleep 3
done
osascript -e "set volume output volume $V"; log "volume devolvido: $(osascript -e 'output volume of (get volume settings)')"
kill $H; log "fim"
