#!/usr/bin/env bash
# Replace contracts/ with RHServer's contracts/ at the given commit. See scripts/contracts.py.
set -euo pipefail
exec python3 "$(dirname "$0")/contracts.py" sync "${1:?usage: scripts/sync-contracts.sh <rhserver-commit>}"
