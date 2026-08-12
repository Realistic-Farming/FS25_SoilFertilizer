#!/usr/bin/env bash
# Run the full FS25_SoilFertilizer self-test suite (syntax + lint + logic tests).
# Usage:  bash tools/test/run.sh   (or: cd tools/test && npm run all)
set -e
cd "$(dirname "$0")"
if [ ! -d node_modules ]; then
  echo "Installing test deps (first run)…"
  npm install --silent
fi
npm run --silent all
