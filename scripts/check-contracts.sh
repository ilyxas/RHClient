#!/usr/bin/env bash
# Verify contracts/ against MANIFEST.sha256, UPSTREAM and RHServer at the UPSTREAM commit.
set -euo pipefail
exec python3 "$(dirname "$0")/contracts.py" check "$@"
