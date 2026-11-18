#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
install -Dm644 clipbridge_path.py "$HOME/.local/bin/clipbridge_path.py"
install -Dm755 clipbridge "$HOME/.local/bin/clipbridge"
install -Dm644 clipbridge-prune.service "$HOME/.config/systemd/user/clipbridge-prune.service"
install -Dm644 clipbridge-prune.timer "$HOME/.config/systemd/user/clipbridge-prune.timer"
systemctl --user daemon-reload
systemctl --user enable --now clipbridge-prune.timer
