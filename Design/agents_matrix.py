#!/usr/bin/env python3
"""Confere o agents.json (tabela de agentes do site) e, com a pasta do site, copia a tabela para o site.js.

O site lê o agents.json da tag do último Release; o bloco MATRIX:BEGIN…END do site.js é a reserva para quando
o GitHub não responde. Chamado pelo release.sh:
    python3 Design/agents_matrix.py agents.json [pasta-do-site]
Sai com erro (e não mexe no site) se o arquivo estiver malformado ou citar um texto que o site não tem.
"""
import json
import re
import sys
from pathlib import Path


def fail(msg):
    print(f"agents.json: {msg}")
    sys.exit(1)


def check(data):
    cols = data.get("columns")
    rows = data.get("rows")
    if not isinstance(cols, list) or not cols or not all(isinstance(c, str) and c for c in cols):
        fail("'columns' precisa ser uma lista de nomes")
    if len(set(cols)) != len(cols):
        fail("coluna repetida")
    if not isinstance(rows, list) or not rows:
        fail("'rows' precisa ser uma lista")
    keys = {"c_" + c for c in cols} | {"c_" + c + "_d" for c in cols}
    agents = 0
    for i, r in enumerate(rows, 1):
        if not isinstance(r, dict):
            fail(f"linha {i} não é um objeto")
        if "group" in r:
            keys.add(r["group"])
            continue
        name, f = r.get("name"), r.get("f")
        if not isinstance(name, str) or not name:
            fail(f"linha {i} sem 'name'")
        if not isinstance(f, str) or len(f) != len(cols) or re.search(r"[^YP-]", f):
            fail(f"{name}: 'f' precisa ter {len(cols)} letras entre Y, P e -")
        icon = r.get("icon")
        if icon is not None and not re.fullmatch(r"[\w.-]+\.(svg|png)", icon):
            fail(f"{name}: ícone inválido ({icon})")
        notes = r.get("notes", {})
        if not isinstance(notes, dict) or any(c not in cols for c in notes):
            fail(f"{name}: 'notes' só pode usar nomes de colunas")
        for c, k in notes.items():
            if f[cols.index(c)] != "P":
                fail(f"{name}: nota em '{c}', mas a coluna não está como P")
            keys.add(k)
        if "sub" in r:
            keys.add(r["sub"])
        agents += 1
    if not agents:
        fail("nenhum agente")
    return keys


def js_row(r):
    if "group" in r:
        return f'  {{ group: {json.dumps(r["group"])} }},'
    parts = [f'name: {json.dumps(r["name"], ensure_ascii=False)}']
    if "icon" in r:
        parts.append(f'icon: {json.dumps(r["icon"])}')
    parts.append(f'f: {json.dumps(r["f"])}')
    if r.get("notes"):
        parts.append("notes: { " + ", ".join(f"{c}: {json.dumps(k)}" for c, k in r["notes"].items()) + " }")
    if "sub" in r:
        parts.append(f'sub: {json.dumps(r["sub"])}')
    return "  { " + ", ".join(parts) + " },"


def main():
    if len(sys.argv) < 2:
        fail("uso: agents_matrix.py agents.json [pasta-do-site]")
    try:
        data = json.loads(Path(sys.argv[1]).read_text())
    except (OSError, ValueError) as e:
        fail(f"não deu para ler ({e})")
    keys = check(data)
    site = Path(sys.argv[2]) if len(sys.argv) > 2 else None
    if not site or not (site / "site.js").is_file():
        print("agents.json: ok (site não encontrado; reserva do site.js não atualizada)")
        return
    # Textos que o site ainda não tem: a tabela de verdade os deixaria de fora, então para aqui.
    i18n = (site / "i18n.js").read_text()
    en = i18n[i18n.index("  en: {"):i18n.index('  "pt-BR": {')]
    missing = sorted(k for k in keys if not re.search(rf"^    {re.escape(k)}:", en, re.M))
    if missing:
        fail("o site ainda não tem estes textos (i18n.js): " + ", ".join(missing))
    js = site / "site.js"
    src = js.read_text()
    start, end = "/* MATRIX:BEGIN (release.sh) */\n", "/* MATRIX:END */"
    if start not in src or end not in src:
        fail("site.js sem os marcadores MATRIX:BEGIN/END")
    block = (start + "const MATRIX_COLS = " + json.dumps(data["columns"]) + ";\n"
             + "const MATRIX = [\n" + "\n".join(js_row(r) for r in data["rows"]) + "\n];\n")
    a, b = src.index(start), src.index(end)
    js.write_text(src[:a] + block + src[b:])
    print(f"agents.json: ok, reserva do site atualizada ({sum('name' in r for r in data['rows'])} agentes)")


if __name__ == "__main__":
    main()
