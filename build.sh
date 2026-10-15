#!/bin/bash
# NotiMirror.app 을 빌드하고 서명한다. --install 을 주면 ~/Applications 에 설치하고 실행한다.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/NotiMirror.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target arm64-apple-macos26.0 \
  -framework AppKit -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo \
  -framework QuartzCore -framework ServiceManagement -framework UserNotifications \
  Sources/*.swift -o "$APP/Contents/MacOS/NotiMirror"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 개발 인증서로 서명해야 재빌드해도 화면 기록 권한이 유지된다 (ad-hoc 서명은 빌드마다 권한이 풀림).
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "빌드 완료: $APP (서명: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x NotiMirror 2>/dev/null || true
  # 이전 프로세스가 완전히 끝나기 전에 open 하면 LaunchServices가 -600 오류를 낸다.
  for _ in $(seq 1 20); do pgrep -x NotiMirror >/dev/null || break; sleep 0.25; done
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/NotiMirror.app"
  ditto "$APP" "$HOME/Applications/NotiMirror.app"
  open "$HOME/Applications/NotiMirror.app"
  echo "설치 및 실행: ~/Applications/NotiMirror.app"
fi
