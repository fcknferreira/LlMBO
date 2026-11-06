#!/bin/bash
# Desenha os widgets em PNG sem a galeria do macOS: copia Sources/LlMBOWidget, troca o @Environment(widgetFamily)
# por parâmetro, tira o @main e renderiza com ImageRenderer (pequeno 170, médio 364x170, @2x, moldura de 22 pt).
# Uso: Design/widget_render/render.sh [prefixo]  → PNGs em Design/widget_render/out/ (fora do git).
set -euo pipefail
cd "$(dirname "$0")"; R="$(cd ../.. && pwd)"; mkdir -p out; cd out
sed -e 's/@Environment(\\.widgetFamily) var family/var family: WidgetFamily = .systemSmall/' -e 's/^@main$//' \
    -e 's/^import LlMBOWidgetModel$//' "$R/Sources/LlMBOWidget/LlMBOWidget.swift" > W.swift
cp "$R/Sources/WidgetModel/WidgetSnapshot.swift" M.swift
swiftc -O -parse-as-library -target arm64-apple-macos14.0 M.swift W.swift ../main.swift -o render
rm -rf Fonts; cp -R "$R/Resources/Fonts" .
./render "${1:-widget}"
