#!/bin/bash
# Extrai os textos da interface com o compilador e regera Resources/{en,es}.lproj/Localizable.strings
# a partir da tabela em Design/translations.py. Falha listando as chaves sem tradução.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
swift build -c release -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >/dev/null
python3 - "$OUT" > "$OUT/keys.txt" <<'PY'
import json, sys, glob
keys = []
for f in sorted(glob.glob(sys.argv[1] + "/*.stringsdata")):
    for tbl in json.load(open(f)).get("tables", {}).values():
        for e in tbl:
            if e["key"] not in keys: keys.append(e["key"])
for k in keys: print(json.dumps(k, ensure_ascii=False))
PY
python3 Design/translations.py "$OUT/keys.txt" Resources
