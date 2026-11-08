#!/usr/bin/env python3
"""Confere o agents.json (tabela de agentes do site) e, com a pasta do site, copia a tabela para o site.js.

O site lê o agents.json da tag do último Release; o bloco MATRIX:BEGIN…END do site.js é a reserva para quando
o GitHub não responde. Chamado pelo release.sh:
    python3 Design/agents_matrix.py agents.json [pasta-do-site]
Sai com erro (e não mexe no site) se o arquivo estiver malformado ou se um texto citado pela tabela faltar em
"texts" (sem "en" ou sem um dos idiomas principais do site). Os textos da tabela moram no próprio agents.json
(pedido do usuário, 08/11/2026): acrescentar, mudar ou tirar um texto chega ao site pelo Release, sem upload.
"""
import base64
import json
import re
import shutil
import sys
from pathlib import Path

ICON_TYPES = {".svg": "image/svg+xml", ".png": "image/png"}


def icons_json(icons_dir):
    """Logos dos agentes (Design/agent-icons/) como data URIs, para o agent-icons.json que vai no Release."""
    out = {}
    for f in sorted(icons_dir.iterdir()):
        if f.suffix in ICON_TYPES:
            out[f.name] = f"data:{ICON_TYPES[f.suffix]};base64," + base64.b64encode(f.read_bytes()).decode()
    return out


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
    # Faixas animadas da home (pedido do usuário, 08/11/2026): ordem, fora e nomes curtos vêm daqui.
    names = [r["name"] for r in rows if "name" in r]
    with_icon = [r["name"] for r in rows if "name" in r and "icon" in r]
    mq = data.get("marquee")
    if not isinstance(mq, dict) or not isinstance(mq.get("lanes"), list) or len(mq["lanes"]) != 2 \
            or not all(isinstance(l, list) for l in mq["lanes"]):
        fail("'marquee.lanes' precisa ser duas listas de nomes de linhas da tabela")
    placed = mq["lanes"][0] + mq["lanes"][1] + list(mq.get("skip", []))
    bad = sorted({n for n in placed + list(mq.get("names", {})) if n not in names})
    if bad:
        fail("marquee cita linhas que a tabela não tem: " + ", ".join(bad))
    twice = sorted({n for n in placed if placed.count(n) > 1})
    if twice:
        fail("marquee repete: " + ", ".join(twice))
    noicon = sorted(n for n in mq["lanes"][0] + mq["lanes"][1] if n not in with_icon)
    if noicon:
        fail("marquee com linha sem logo: " + ", ".join(noicon))
    loose = [n for n in with_icon if n not in placed]
    if loose:
        print("agents.json: entram nas faixas sozinhos, alternando: " + ", ".join(loose))
    texts = data.get("texts")
    if not isinstance(texts, dict):
        fail("'texts' precisa ser um objeto (chave → {idioma: texto})")
    for k, v in texts.items():
        if not isinstance(v, dict) or not v or not all(isinstance(l, str) and isinstance(x, str) and x for l, x in v.items()):
            fail(f"texts.{k}: precisa ser {{idioma: texto}} sem texto vazio")
    missing = sorted(k for k in keys if "en" not in texts.get(k, {}))
    if missing:
        fail("faltam textos (pelo menos em inglês) em 'texts': " + ", ".join(missing))
    unused = sorted(set(texts) - keys)
    if unused:
        print("agents.json: aviso, textos sem uso na tabela (podem sair): " + ", ".join(unused))
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
    # Logos (pedido do usuário, 08/11/2026): moram em Design/agent-icons/ e viajam no agent-icons.json da tag do
    # Release, que o site lê junto com a tabela. Logo citado na tabela e ausente na pasta = erro.
    repo = Path(sys.argv[1]).resolve().parent
    icons_dir = repo / "Design" / "agent-icons"
    if not icons_dir.is_dir():
        fail("falta a pasta Design/agent-icons/ com os logos dos agentes")
    absent = sorted({r["icon"] for r in data["rows"] if "icon" in r and not (icons_dir / r["icon"]).is_file()})
    if absent:
        fail("logo citado na tabela e ausente em Design/agent-icons/: " + ", ".join(absent))
    icons = icons_json(icons_dir)
    text = "{\n" + ",\n".join(f"  {json.dumps(k)}: {json.dumps(v)}" for k, v in icons.items()) + "\n}\n"
    (repo / "agent-icons.json").write_text(text)
    print(f"agent-icons.json: {len(icons)} logos, {len(text) // 1024} KB")
    site = Path(sys.argv[2]) if len(sys.argv) > 2 else None
    if not site or not (site / "site.js").is_file():
        print("agents.json: ok (site não encontrado; reserva do site.js não atualizada)")
        return
    # Idiomas do site: os principais (sem _base) são obrigatórios em cada texto da tabela; en-GB, es-419 e pt-PT
    # herdam do inglês, do espanhol e do português do Brasil quando não têm o seu.
    i18n = (site / "i18n.js").read_text(encoding="utf-8")
    heads = list(re.finditer(r'^  "?([A-Za-z]{2}(?:-[A-Za-z0-9]+)?)"?: \{', i18n, re.M))
    langs = {}
    for i, m in enumerate(heads):
        body = i18n[m.end():heads[i + 1].start() if i + 1 < len(heads) else len(i18n)]
        langs[m.group(1)] = "_base:" in body
    main_langs = sorted(l for l, variant in langs.items() if not variant)
    texts = data["texts"]
    gaps = [f"{k} ({', '.join(l for l in main_langs if l not in texts[k])})" for k in sorted(keys)
            if any(l not in texts[k] for l in main_langs)]
    if gaps:
        fail("textos sem tradução para um idioma do site: " + "; ".join(gaps))
    strange = sorted({l for v in texts.values() for l in v if l not in langs})
    if strange:
        fail("idioma que o site não tem em 'texts': " + ", ".join(strange))
    js = site / "site.js"
    src = js.read_text(encoding="utf-8")
    start, end = "/* MATRIX:BEGIN (release.sh) */\n", "/* MATRIX:END */"
    if start not in src or end not in src:
        fail("site.js sem os marcadores MATRIX:BEGIN/END")
    used = {k: data["texts"][k] for k in data["texts"] if k in keys}
    block = (start + "const MATRIX_COLS = " + json.dumps(data["columns"]) + ";\n"
             + "const MATRIX = [\n" + "\n".join(js_row(r) for r in data["rows"]) + "\n];\n"
             + "const MATRIX_TEXTS = {\n"
             + "\n".join(f"  {json.dumps(k)}: {json.dumps(v, ensure_ascii=False)}," for k, v in used.items())
             + "\n};\n"
             + "const MARQUEE = " + json.dumps(data["marquee"], ensure_ascii=False) + ";\n")
    a, b = src.index(start), src.index(end)
    js.write_text(src[:a] + block + src[b:], encoding="utf-8")
    # Reserva dos logos no próprio site (agent-icons.js, como o make_agent_icons.py do site): copia os da pasta.
    assets = site / "assets" / "agents"
    if assets.is_dir():
        for f in icons_dir.iterdir():
            if f.suffix in ICON_TYPES:
                shutil.copyfile(f, assets / f.name)
        site_icons = icons_json(assets)
        (site / "agent-icons.js").write_text(
            "// Generated by make_agent_icons.py from assets/agents/ — do not edit by hand.\n"
            "const AGENT_ICONS = " + json.dumps(site_icons, indent=0) + ";\n")
    print(f"agents.json: ok, reserva do site atualizada ({sum('name' in r for r in data['rows'])} agentes)")


if __name__ == "__main__":
    main()
