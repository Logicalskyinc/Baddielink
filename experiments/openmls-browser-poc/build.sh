#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p pkg
wasm-pack build --target web --out-dir pkg
cp static/index.html pkg/index.html
