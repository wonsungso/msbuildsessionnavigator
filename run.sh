#!/usr/bin/env bash
# MS Build 2026 Session Navigator – 서버 시작
# Python 미설치 환경 자동 처리 + venv 기반 패키지 격리

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/.server.pid"
LOG_FILE="$SCRIPT_DIR/.server.log"
VENV_DIR="$SCRIPT_DIR/.venv"
PORT=5500

# ─────────────────────────────────────────────────────────────────
# 1. Python 3.8+ 탐색
# ─────────────────────────────────────────────────────────────────
PYTHON=""
for cmd in python3 python python3.13 python3.12 python3.11 python3.10 python3.9 python3.8; do
  if command -v "$cmd" &>/dev/null; then
    if "$cmd" -c "import sys; exit(0 if sys.version_info >= (3,8) else 1)" 2>/dev/null; then
      PYTHON="$cmd"
      break
    fi
  fi
done

if [[ -z "$PYTHON" ]]; then
  echo "⚠  Python 3.8+ 를 찾을 수 없습니다. 자동 설치를 시도합니다..."
  OS="$(uname -s)"
  case "$OS" in
    Darwin)
      if command -v brew &>/dev/null; then
        echo "   [Homebrew] python3 설치 중..."
        brew install python3
      else
        echo "   [Homebrew] 먼저 Homebrew를 설치합니다..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        brew install python3
      fi
      PYTHON="python3"
      ;;
    Linux)
      if command -v apt-get &>/dev/null; then
        echo "   [apt] python3 + python3-venv 설치 중..."
        sudo apt-get update -qq && sudo apt-get install -y python3 python3-venv python3-pip
      elif command -v dnf &>/dev/null; then
        echo "   [dnf] python3 설치 중..."
        sudo dnf install -y python3 python3-pip
      elif command -v yum &>/dev/null; then
        echo "   [yum] python3 설치 중..."
        sudo yum install -y python3 python3-pip
      elif command -v pacman &>/dev/null; then
        echo "   [pacman] python 설치 중..."
        sudo pacman -Sy --noconfirm python python-pip
      elif command -v apk &>/dev/null; then
        echo "   [apk] python3 설치 중..."
        sudo apk add --no-cache python3 py3-pip
      elif command -v zypper &>/dev/null; then
        echo "   [zypper] python3 설치 중..."
        sudo zypper install -y python3 python3-pip
      else
        echo "❌ 지원하지 않는 Linux 배포판입니다."
        echo "   수동으로 Python 3.8+ 를 설치한 후 다시 실행해주세요:"
        echo "   https://www.python.org/downloads/"
        exit 1
      fi
      PYTHON="python3"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      if command -v winget &>/dev/null; then
        echo "   [winget] Python 3.12 설치 중..."
        winget install -e --id Python.Python.3.12 \
          --accept-package-agreements --accept-source-agreements
        export PATH="$PATH:/c/Users/$USERNAME/AppData/Local/Programs/Python/Python312"
        PYTHON="python"
      else
        echo "❌ Python 3.8+ 가 필요합니다."
        echo "   https://www.python.org/downloads/windows/"
        exit 1
      fi
      ;;
    *)
      echo "❌ 알 수 없는 OS: $OS"
      echo "   https://www.python.org/downloads/"
      exit 1
      ;;
  esac

  if ! "$PYTHON" -c "import sys; exit(0 if sys.version_info >= (3,8) else 1)" 2>/dev/null; then
    echo "❌ Python 설치 후에도 실행이 안 됩니다. 터미널을 재시작한 뒤 다시 시도하세요."
    exit 1
  fi
fi

echo "✔  $("$PYTHON" --version 2>&1)"

# ─────────────────────────────────────────────────────────────────
# 2. venv 생성 (없을 때만)
# ─────────────────────────────────────────────────────────────────
if [[ ! -d "$VENV_DIR" ]]; then
  echo "🔧  가상환경 생성 중 (.venv)..."

  # python3-venv 모듈이 없는 Debian/Ubuntu 계열 대응
  if ! "$PYTHON" -m venv --help &>/dev/null 2>&1; then
    echo "   [apt] python3-venv 설치 중..."
    sudo apt-get install -y python3-venv python3-full 2>/dev/null || true
  fi

  "$PYTHON" -m venv "$VENV_DIR"
  echo "✔  가상환경 생성 완료"
fi

# venv 내부 Python/pip 사용
VENV_PYTHON="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"
# Windows Git Bash 경로 대응
[[ ! -f "$VENV_PYTHON" ]] && VENV_PYTHON="$VENV_DIR/Scripts/python.exe"
[[ ! -f "$VENV_PIP"    ]] && VENV_PIP="$VENV_DIR/Scripts/pip.exe"

# ─────────────────────────────────────────────────────────────────
# 3. 필수 패키지 설치 (venv 안에서)
# ─────────────────────────────────────────────────────────────────
if ! "$VENV_PYTHON" -c "import requests" &>/dev/null; then
  echo "📦  requests 설치 중 (venv)..."
  "$VENV_PIP" install --quiet requests
fi

echo "✔  의존성 확인 완료"

# ─────────────────────────────────────────────────────────────────
# 4. 이미 실행 중인지 확인
# ─────────────────────────────────────────────────────────────────
if [[ -f "$PID_FILE" ]]; then
  PID=$(cat "$PID_FILE")
  if kill -0 "$PID" 2>/dev/null; then
    echo "⚠  서버가 이미 실행 중입니다 (PID $PID)"
    echo "   http://localhost:$PORT"
    exit 0
  fi
  rm -f "$PID_FILE"
fi

# ─────────────────────────────────────────────────────────────────
# 5. 서버 시작 (venv Python 사용)
# ─────────────────────────────────────────────────────────────────
echo "▶  서버 시작 중..."
cd "$SCRIPT_DIR"
nohup "$VENV_PYTHON" server.py > "$LOG_FILE" 2>&1 &
PID=$!
echo "$PID" > "$PID_FILE"

# 최대 5초 대기
for i in {1..10}; do
  sleep 0.5
  if curl -sf "http://localhost:$PORT/" > /dev/null 2>&1; then
    echo "✅  서버 실행 완료 (PID $PID)"
    echo "   http://localhost:$PORT"
    echo "   로그: $LOG_FILE"
    exit 0
  fi
done

echo "✅  서버 기동됨 (PID $PID) – 포트 응답 대기 중"
echo "   http://localhost:$PORT"
echo "   로그: $LOG_FILE"


# ─────────────────────────────────────────────────────────────────
# 1. Python 3.8+ 탐색
# ─────────────────────────────────────────────────────────────────
PYTHON=""
for cmd in python3 python python3.13 python3.12 python3.11 python3.10 python3.9 python3.8; do
  if command -v "$cmd" &>/dev/null; then
    if "$cmd" -c "import sys; exit(0 if sys.version_info >= (3,8) else 1)" 2>/dev/null; then
      PYTHON="$cmd"
      break
    fi
  fi
done

if [[ -z "$PYTHON" ]]; then
  echo "⚠  Python 3.8+ 를 찾을 수 없습니다. 자동 설치를 시도합니다..."
  OS="$(uname -s)"
  case "$OS" in
    Darwin)
      if command -v brew &>/dev/null; then
        echo "   [Homebrew] python3 설치 중..."
        brew install python3
      else
        echo "   [Homebrew] 먼저 Homebrew를 설치합니다..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        brew install python3
      fi
      PYTHON="python3"
      ;;
    Linux)
      if command -v apt-get &>/dev/null; then
        echo "   [apt] python3 설치 중..."
        sudo apt-get update -qq && sudo apt-get install -y python3 python3-pip
      elif command -v dnf &>/dev/null; then
        echo "   [dnf] python3 설치 중..."
        sudo dnf install -y python3 python3-pip
      elif command -v yum &>/dev/null; then
        echo "   [yum] python3 설치 중..."
        sudo yum install -y python3 python3-pip
      elif command -v pacman &>/dev/null; then
        echo "   [pacman] python 설치 중..."
        sudo pacman -Sy --noconfirm python python-pip
      elif command -v apk &>/dev/null; then
        echo "   [apk] python3 설치 중..."
        sudo apk add --no-cache python3 py3-pip
      elif command -v zypper &>/dev/null; then
        echo "   [zypper] python3 설치 중..."
        sudo zypper install -y python3 python3-pip
      else
        echo "❌ 지원하지 않는 Linux 배포판입니다."
        echo "   수동으로 Python 3.8+ 를 설치한 후 다시 실행해주세요:"
        echo "   https://www.python.org/downloads/"
        exit 1
      fi
      PYTHON="python3"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      # Windows (Git Bash / MSYS2)
      if command -v winget &>/dev/null; then
        echo "   [winget] Python 3.12 설치 중..."
        winget install -e --id Python.Python.3.12 \
          --accept-package-agreements --accept-source-agreements
        # PATH 갱신 (Git Bash 세션)
        export PATH="$PATH:/c/Users/$USERNAME/AppData/Local/Programs/Python/Python312"
        PYTHON="python"
      else
        echo "❌ Python 3.8+ 가 필요합니다."
        echo ""
        echo "   ① 아래 링크에서 설치 (설치 시 'Add to PATH' 체크):"
        echo "      https://www.python.org/downloads/windows/"
        echo ""
        echo "   ② 또는 Microsoft Store에서 설치:"
        echo "      ms-windows-store://pdp/?ProductId=9NCVDN91XZQP"
        echo ""
        echo "   ③ 또는 winget 사용:"
        echo "      winget install -e --id Python.Python.3.12"
        echo ""
        echo "   설치 후 터미널을 재시작하고 다시 run.sh 를 실행하세요."
        exit 1
      fi
      ;;
    *)
      echo "❌ 알 수 없는 OS: $OS"
      echo "   Python 3.8+ 를 수동으로 설치한 후 다시 실행해주세요:"
      echo "   https://www.python.org/downloads/"
      exit 1
      ;;
  esac

  # 재확인
  if ! "$PYTHON" -c "import sys; exit(0 if sys.version_info >= (3,8) else 1)" 2>/dev/null; then
    echo "❌ Python 설치 후에도 실행이 안 됩니다. 터미널을 재시작한 뒤 다시 시도하세요."
    exit 1
  fi
fi

PY_VER="$("$PYTHON" --version 2>&1)"
echo "✔  $PY_VER"

# ─────────────────────────────────────────────────────────────────
# 2. pip 및 필수 패키지 확인
# ─────────────────────────────────────────────────────────────────
# pip 없으면 ensurepip으로 설치
if ! "$PYTHON" -m pip --version &>/dev/null; then
  echo "📦  pip 없음 → 설치 중..."
  "$PYTHON" -m ensurepip --upgrade || {
    echo "   ensurepip 실패. get-pip.py 로 재시도..."
    curl -fsSL https://bootstrap.pypa.io/get-pip.py | "$PYTHON"
  }
fi

# requests 패키지 확인
if ! "$PYTHON" -c "import requests" &>/dev/null; then
  echo "📦  requests 설치 중..."
  "$PYTHON" -m pip install --quiet requests
fi

echo "✔  의존성 확인 완료"

# ─────────────────────────────────────────────────────────────────
# 3. 이미 실행 중인지 확인
# ─────────────────────────────────────────────────────────────────
if [[ -f "$PID_FILE" ]]; then
  PID=$(cat "$PID_FILE")
  if kill -0 "$PID" 2>/dev/null; then
    echo "⚠  서버가 이미 실행 중입니다 (PID $PID)"
    echo "   http://localhost:$PORT"
    exit 0
  fi
  rm -f "$PID_FILE"
fi

# ─────────────────────────────────────────────────────────────────
# 4. 서버 시작
# ─────────────────────────────────────────────────────────────────
echo "▶  서버 시작 중..."
cd "$SCRIPT_DIR"
nohup "$PYTHON" server.py > "$LOG_FILE" 2>&1 &
PID=$!
echo "$PID" > "$PID_FILE"

# 최대 5초 대기
for i in {1..10}; do
  sleep 0.5
  if curl -sf "http://localhost:$PORT/" > /dev/null 2>&1; then
    echo "✅  서버 실행 완료 (PID $PID)"
    echo "   http://localhost:$PORT"
    echo "   로그: $LOG_FILE"
    exit 0
  fi
done

echo "✅  서버 기동됨 (PID $PID) – 포트 응답 대기 중"
echo "   http://localhost:$PORT"
echo "   로그: $LOG_FILE"

