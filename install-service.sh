#!/usr/bin/env bash
# MS Build 2026 Session Navigator – 서비스 설치
# - systemd 등록 (부팅 시 자동 시작, 비정상 종료 시 자동 재시작)
# - cron 등록 (매일 새벽 4시 자동 재시작)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="msbuild-navigator"
SERVICE_FILE="$SCRIPT_DIR/$SERVICE_NAME.service"
SERVICE_DEST="/etc/systemd/system/$SERVICE_NAME.service"
CRON_JOB="0 4 * * * systemctl restart $SERVICE_NAME >> $SCRIPT_DIR/.restart.log 2>&1"

# ─────────────────────────────────────────────────────────────────
# 1. root 확인
# ─────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "❌ root 권한이 필요합니다: sudo bash $0"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────
# 2. 서비스 파일의 WorkingDirectory / PIDFile 경로를 실제 경로로 치환
# ─────────────────────────────────────────────────────────────────
sed "s|/root/msbuildsessionnavigator|$SCRIPT_DIR|g" "$SERVICE_FILE" > "$SERVICE_DEST"
echo "✔  서비스 파일 설치: $SERVICE_DEST"

# ─────────────────────────────────────────────────────────────────
# 3. systemd 등록 및 시작
# ─────────────────────────────────────────────────────────────────
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"

# 기존 프로세스가 있으면 먼저 중지
bash "$SCRIPT_DIR/stop.sh" 2>/dev/null || true

systemctl start "$SERVICE_NAME"
echo "✔  서비스 시작 완료"
systemctl status "$SERVICE_NAME" --no-pager

# ─────────────────────────────────────────────────────────────────
# 4. cron 등록 (매일 새벽 4시 재시작, 중복 방지)
# ─────────────────────────────────────────────────────────────────
CRONTAB=$(crontab -l 2>/dev/null || true)
if echo "$CRONTAB" | grep -qF "systemctl restart $SERVICE_NAME"; then
  echo "ℹ  cron 이미 등록되어 있습니다"
else
  (echo "$CRONTAB"; echo "$CRON_JOB") | crontab -
  echo "✔  cron 등록 완료 (매일 04:00 자동 재시작)"
fi

echo ""
echo "═══════════════════════════════════════════"
echo "  설치 완료"
echo "  상태 확인: systemctl status $SERVICE_NAME"
echo "  로그 확인: journalctl -u $SERVICE_NAME -f"
echo "  cron 확인: crontab -l"
echo "═══════════════════════════════════════════"
