#!/bin/zsh
set -uo pipefail
PROJECT_ROOT="${0:A:h:h}"
cd "$PROJECT_ROOT"
"$PROJECT_ROOT/local/cloud-venv/bin/python" "$PROJECT_ROOT/scripts/fetch-device-schema.py"
print '\nPress Enter to close.'
read -r
