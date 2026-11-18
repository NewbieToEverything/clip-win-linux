#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
install -Dm644 clipbridge_path.py "$HOME/.local/bin/clipbridge_path.py"
install -Dm755 clipbridge "$HOME/.local/bin/clipbridge"
