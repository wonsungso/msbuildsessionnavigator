#!/usr/bin/env python3
"""
MS Build 2026 Session Navigator – Auto-updating HTTP Server
 - HTTPS(443) 또는 HTTP(80)으로 파일 서빙
 - SSL 인증서가 있으면 HTTPS, 없으면 HTTP 자동 폴백
 - 백그라운드에서 24시간마다 sessions.json 자동 갱신
 - 갱신 시 sessions_kr.json (한국어 번역) 자동 생성/업데이트
"""
import http.server
import socketserver
import threading
import time
import json
import os
import sys
import ssl
import requests
from datetime import datetime, timezone
from pathlib import Path

# ── 설정 ──────────────────────────────────────────────────────────
PORT         = 443
HTTP_PORT    = 80
SSL_CERT     = "/etc/letsencrypt/live/msbuild.wonsungso.shop/fullchain.pem"
SSL_KEY      = "/etc/letsencrypt/live/msbuild.wonsungso.shop/privkey.pem"
BASE_DIR     = Path(__file__).parent
SESSIONS_URL = "https://api-v2.build.microsoft.com/api/session/all"
FETCH_TIMEOUT = 30    # 외부 API 요청 타임아웃 (초)
KR_FILE      = BASE_DIR / "source" / "sessions_kr.json"
SJ_FILE      = BASE_DIR / "source" / "sessions.json"
(BASE_DIR / "source").mkdir(exist_ok=True)   # source/ 폴더 자동 생성
MAX_AGE_SEC  = 604800  # 7일
CHECK_EVERY  = 86400   # 24시간마다 갱신 여부 확인
XLATE_DELAY  = 0.25    # 번역 요청 간격 (초)
CHUNK_SIZE   = 900     # Google Translate 최대 문자수


# ── 번역 유틸 ──────────────────────────────────────────────────────
def _translate_chunk(text: str, target: str = "ko") -> str:
    url = "https://translate.googleapis.com/translate_a/single"
    params = {"client": "gtx", "sl": "en", "tl": target, "dt": "t", "q": text}
    for attempt in range(3):
        try:
            r = requests.get(url, params=params, timeout=15)
            if r.status_code == 200:
                data = r.json()
                return "".join(p[0] for p in data[0] if p and p[0])
        except Exception:
            pass
        time.sleep(2 ** attempt)
    return text  # 실패 시 원문 반환


def translate_text(text: str, target: str = "ko") -> str:
    if not text or not text.strip():
        return text
    if len(text) <= CHUNK_SIZE:
        return _translate_chunk(text, target)
    # 긴 텍스트는 문장 단위로 분할 번역
    sentences = text.replace(". ", ".\n").split("\n")
    chunks, buf = [], ""
    for sent in sentences:
        if len(buf) + len(sent) + 1 > CHUNK_SIZE:
            if buf:
                chunks.append(buf.strip())
            buf = sent
        else:
            buf = (buf + " " + sent).strip()
    if buf:
        chunks.append(buf.strip())
    return " ".join(_translate_chunk(c, target) for c in chunks if c)


# ── 세션 데이터 취득 ───────────────────────────────────────────────
def fetch_sessions() -> list:
    print(f"[{_ts()}] API에서 세션 데이터 취득 중...")
    r = requests.get(SESSIONS_URL, timeout=FETCH_TIMEOUT)
    r.raise_for_status()
    data = r.json()
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        for key in ("value", "sessions", "data"):
            if isinstance(data.get(key), list):
                return data[key]
        for v in data.values():
            if isinstance(v, list):
                return v
    return []


def _ts() -> str:
    return datetime.now().strftime("%H:%M:%S")


# ── 핵심 업데이트 함수 ──────────────────────────────────────────────
def do_update():
    try:
        # 1. 세션 데이터 취득
        sessions = fetch_sessions()
        if not sessions:
            print(f"[{_ts()}] 세션 없음, 건너뜀")
            return

        # 2. sessions.json 저장
        with open(SJ_FILE, "w", encoding="utf-8") as f:
            json.dump(sessions, f, ensure_ascii=False)
        print(f"[{_ts()}] sessions.json 저장 완료 ({len(sessions)}개)")

        # 3. 기존 번역 불러오기 (이미 번역된 항목은 재번역 안 함)
        existing = {}
        if KR_FILE.exists():
            try:
                with open(KR_FILE, "r", encoding="utf-8") as f:
                    existing = json.load(f).get("translations", {})
            except Exception:
                pass

        # 4. 중복 제거
        seen, unique = set(), []
        for s in sessions:
            k = s.get("sessionCode") or s.get("sessionId")
            if k and k not in seen:
                seen.add(k)
                unique.append(s)

        # 5. 번역 (새 항목만) – 10개마다 중간 저장
        translations = dict(existing)
        new_count = 0

        def _save_kr(final=False):
            output = {
                "last_updated":  datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "session_count": len(unique),
                "translations":  translations,
            }
            tmp = KR_FILE.with_suffix(".tmp")
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(output, f, ensure_ascii=False, indent=2)
            tmp.replace(KR_FILE)   # atomic rename
            if final:
                print(f"[{_ts()}] sessions_kr.json 저장 완료 "
                      f"(신규 {new_count}개, 누적 {len(translations)}개)")

        for i, s in enumerate(unique):
            sid = s.get("sessionId") or s.get("sessionCode")
            if not sid or sid in translations:
                continue
            title = s.get("title", "")
            desc  = s.get("ogDescription") or s.get("description") or ""
            print(f"[{i+1}/{len(unique)}] 번역 중: {title[:55]}...")
            desc_kr = translate_text(desc)
            time.sleep(XLATE_DELAY)
            translations[sid] = {"title": title, "description_kr": desc_kr}
            new_count += 1
            # 10개마다 중간 저장
            if new_count % 10 == 0:
                _save_kr()
                print(f"[{_ts()}] 중간 저장 ({new_count}개 완료)")

        _save_kr(final=True)

        # 6. session_count를 실제 자엄 수로 업데이트 (완료 시점)
        with open(KR_FILE, "r", encoding="utf-8") as f:
            _final = json.load(f)
        _final["session_count"] = len(unique)
        with open(KR_FILE, "w", encoding="utf-8") as f:
            json.dump(_final, f, ensure_ascii=False, indent=2)

    except Exception as e:
        print(f"[{_ts()}] 업데이트 오류: {e}", file=sys.stderr)


# ── 갱신 여부 판단 ─────────────────────────────────────────────────
def is_stale() -> bool:
    if not KR_FILE.exists():
        return True
    try:
        with open(KR_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        lu = datetime.strptime(
            data.get("last_updated", "2000-01-01T00:00:00Z"),
            "%Y-%m-%dT%H:%M:%SZ",
        )
        if (datetime.now(timezone.utc).replace(tzinfo=None) - lu).total_seconds() > MAX_AGE_SEC:
            return True
        # 번역 미완료 세션이 있으면 갱신 필요
        expected = data.get("session_count", 0)
        actual   = len(data.get("translations", {}))
        if actual < expected:
            print(f"[{_ts()}] 번역 미완료: {actual}/{expected} → 이어서 번역")
            return True
        return False
    except Exception:
        return True


# ── 백그라운드 스레드 ──────────────────────────────────────────────
def background_updater():
    if is_stale():
        print(f"[{_ts()}] 데이터 없음 또는 만료 → 즉시 업데이트 시작")
        do_update()
    else:
        print(f"[{_ts()}] 데이터 최신 상태, 다음 체크까지 대기")

    while True:
        time.sleep(CHECK_EVERY)
        if is_stale():
            print(f"[{_ts()}] 7일 경과 → 자동 업데이트 시작")
            do_update()


# ── HTTP 서버 ──────────────────────────────────────────────────────
class QuietHandler(http.server.SimpleHTTPRequestHandler):
    """정적 파일 서빙 (액세스 로그 간소화)"""
    def end_headers(self):
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('X-Frame-Options', 'SAMEORIGIN')
        self.send_header('Referrer-Policy', 'strict-origin-when-cross-origin')
        self.send_header(
            'Content-Security-Policy',
            "default-src 'self'; "
            "script-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com; "
            "connect-src 'self' https://translate.googleapis.com; "
            "img-src 'self' data:; "
            "style-src 'self' 'unsafe-inline'"
        )
        super().end_headers()

    def log_message(self, fmt, *args):
        # 에러만 출력
        if args and str(args[1]) >= "400":
            super().log_message(fmt, *args)


if __name__ == "__main__":
    os.chdir(BASE_DIR)

    # 백그라운드 업데이터 시작
    t = threading.Thread(target=background_updater, daemon=True)
    t.start()

    # SSL 컨텍스트 설정
    ssl_available = Path(SSL_CERT).exists() and Path(SSL_KEY).exists()
    if ssl_available:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(SSL_CERT, SSL_KEY)
    else:
        print(f"[WARNING] SSL 인증서를 찾을 수 없습니다: {SSL_CERT}")
        print("[WARNING] HTTP 모드로 기동합니다. certbot으로 인증서를 설치하세요.")

    # HTTP → HTTPS 리다이렉트 서버 (80포트)
    class RedirectHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            host = self.headers.get('Host', 'localhost')
            self.send_response(301)
            self.send_header('Location', f'https://{host}{self.path}')
            self.end_headers()
        def do_HEAD(self):
            self.do_GET()
        def log_message(self, fmt, *args):
            pass

    if ssl_available:
        socketserver.ThreadingTCPServer.allow_reuse_address = True
        redirect_server = socketserver.ThreadingTCPServer(("0.0.0.0", HTTP_PORT), RedirectHandler)
        redirect_server.daemon_threads = True
        rt = threading.Thread(target=redirect_server.serve_forever, daemon=True)
        rt.start()

    # HTTPS 서버 시작
    actual_port = PORT if ssl_available else HTTP_PORT
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer(("0.0.0.0", actual_port), QuietHandler) as httpd:
        httpd.daemon_threads = True
        if ssl_available:
            httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
        proto = "https" if ssl_available else "http"
        host = "localhost" if not ssl_available else "<your-domain>"
        print(f"\n{'='*50}")
        print(f"  MS Build 2026 Session Navigator")
        print(f"  {proto}://{host}")
        print(f"  세션 데이터: 7일마다 자동 갱신 (매일 갱신 여부 체크)")
        print(f"{'='*50}\n")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n서버 종료")
