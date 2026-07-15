#!/bin/bash
# Full local test suite (no Docker needed — Node 22+ and bash/tail/tar/unzip).
set -e
cd "$(dirname "$0")/.."
node --check wrapper.js
bash -n entrypoint.sh
node -e "JSON.parse(require('fs').readFileSync('egg-cobalt88-v2.json','utf8'))"
echo "--- wrapper e2e ---"
node test/e2e.js
echo "--- entrypoint scenarios ---"
bash test/entrypoint-tests.sh
