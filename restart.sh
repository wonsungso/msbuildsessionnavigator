#!/usr/bin/env bash
# MS Build 2026 Session Navigator – 서버 재시작
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🔄  서버 재시작..."
bash "$SCRIPT_DIR/stop.sh"
sleep 1
bash "$SCRIPT_DIR/run.sh"
