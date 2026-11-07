#!/usr/bin/env bash
# ============================================================================
#  Сборка mcp-hub.exe на Linux / macOS (нужен mono: apt install mono-mcs)
#  Результат: dist/mcp-hub.exe
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v mcs >/dev/null 2>&1; then
    echo "ОШИБКА: не найден mcs. Установи mono: sudo apt-get install -y mono-mcs"
    exit 1
fi

mkdir -p dist
mcs -target:exe \
    -out:dist/mcp-hub.exe \
    -win32icon:assets/mcp-hub.ico \
    -r:System.dll \
    -resource:mcp-hub.ps1,mcp-hub.ps1 \
    src/Program.cs

echo "Готово: dist/mcp-hub.exe ($(stat -c%s dist/mcp-hub.exe) байт)"
