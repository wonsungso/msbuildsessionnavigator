#!/usr/bin/env bash
# MS Build 2026 Session Navigator – 서버 종료
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/.server.pid"

if [[ ! -f "$PID_FILE" ]]; then
  # PID 파일 없으면 포트로 직접 탐색
  PID=$(lsof -ti tcp:80 2>/dev/null || true)
  if [[ -z "$PID" ]]; then
    echo "ℹ  실행 중인 서버가 없습니다"
    exit 0
  fi
  echo "⏹  서버 종료 중 (PID $PID)..."
  kill "$PID" 2>/dev/null && echo "✅  종료 완료" || echo "⚠  종료 실패"
  exit 0
fi

PID=$(cat "$PID_FILE")

if kill -0 "$PID" 2>/dev/null; then
  echo "⏹  서버 종료 중 (PID $PID)..."
  kill "$PID"
  # 최대 3초 대기
  for i in {1..6}; do
    sleep 0.5
    kill -0 "$PID" 2>/dev/null || break
  done
  if kill -0 "$PID" 2>/dev/null; then
    kill -9 "$PID" 2>/dev/null
  fi
  echo "✅  종료 완료"
else
  echo "ℹ  서버가 이미 종료되어 있습니다 (PID $PID)"
fi

rm -f "$PID_FILE"
