#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p pkg
wasm-pack build --target web --out-dir pkg --out-name openmls_wasm
cp static/index.html pkg/index.html
cp static/mls-lock.js pkg/mls-lock.js
cp static/opfs-storage-worker.js pkg/opfs-storage-worker.js
