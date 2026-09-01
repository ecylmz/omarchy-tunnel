#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
PLUGIN_DIR="$(dirname -- "$TEST_DIR")"
readonly PLUGIN_DIR

cd -- "$PLUGIN_DIR"
node tests/model.test.js
python3 -B -m unittest -v tests/helper_test.py
bash tests/lint.sh
