#!/bin/zsh
set -uo pipefail
PROJECT_ROOT="${0:A:h:h}"
cd "$PROJECT_ROOT"
if [[ ! -x "$PROJECT_ROOT/local/cloud-venv/bin/python" ]]; then
  print 'Set up local/cloud-venv before running this helper.'
else
  "$PROJECT_ROOT/local/cloud-venv/bin/python" "$PROJECT_ROOT/scripts/fetch-local-keys.py"
fi
print '\nPress Enter to close.'
read -r
