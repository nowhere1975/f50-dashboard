#!/bin/bash
# 构建 / 测试 / 安装。仅依赖系统 Swift、Python 3 和 macOS 工具。
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="F50Dashboard"
BUNDLE_ID="io.github.nowhere1975.f50dashboard"
VERSION="0.5.0"
BUILD_DIR="$PROJECT_DIR/build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
SUPPORT="$HOME/Library/Application Support/F50Dashboard"
PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
ARCH="${F50_ARCH:-$(uname -m)}"
info() { printf '  · %s\n' "$1"; }
fail() { printf '  ✗ %s\n' "$1" >&2; exit 1; }

do_build() {
  command -v swiftc >/dev/null || fail "找不到 swiftc，请先运行 xcode-select --install"
  case "$ARCH" in arm64|x86_64) ;; *) fail "不支持的架构：$ARCH" ;; esac
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  sed "s/__VERSION__/$VERSION/g" "$PROJECT_DIR/Resources/Info.plist" > "$APP/Contents/Info.plist"
  local sources=("$PROJECT_DIR"/Sources/F50Dashboard/*.swift)
  swiftc -O -swift-version 5 -target "$ARCH-apple-macosx12.0" \
    -framework Cocoa -framework SystemConfiguration -framework UserNotifications \
    "${sources[@]}" -o "$APP/Contents/MacOS/$APP_NAME"
  codesign --force --deep --sign - "$APP"
  codesign --verify --deep --strict "$APP"
  info "已构建 ${VERSION}（${ARCH}，最低 macOS 12）：$APP"
}

do_test() {
  mkdir -p "$BUILD_DIR/tests"
  local sources=()
  local name
  for name in Config Fmt SysInfo BillingCycle TrafficTracker StateStore RouterClient RouterState DashboardMenu DashboardSnapshot; do
    sources+=("$PROJECT_DIR/Sources/F50Dashboard/$name.swift")
  done
  swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx12.0" \
    -framework SystemConfiguration "${sources[@]}" "$PROJECT_DIR/Tests/main.swift" \
    -o "$BUILD_DIR/tests/regression"
  "$BUILD_DIR/tests/regression"
  swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx12.0" \
    -framework Cocoa -framework SystemConfiguration "${sources[@]}" \
    "$PROJECT_DIR/Sources/F50Dashboard/MenuRenderer.swift" "$PROJECT_DIR/Tests/MenuRenderer/main.swift" \
    -o "$BUILD_DIR/tests/menu-regression"
  "$BUILD_DIR/tests/menu-regression"
  swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx12.0" \
    -framework Cocoa -framework SystemConfiguration "${sources[@]}" \
    "$PROJECT_DIR/Sources/F50Dashboard/DashboardCard.swift" "$PROJECT_DIR/Tests/Dashboard/main.swift" \
    -o "$BUILD_DIR/tests/dashboard-regression"
  "$BUILD_DIR/tests/dashboard-regression"
  python3 "$PROJECT_DIR/Tests/scripts_test.py"
  bash -n "$PROJECT_DIR/build.sh"
  bash -n "$PROJECT_DIR/tools/router-traffic.sh"
  bash -n "$PROJECT_DIR/tools/ssid-traffic.sh"
}

do_install() {
  do_build
  # 0.1 没有信号保存处理；必须先通过菜单退出一次，避免丢失整段内存累计。
  if [ -x "$INSTALLED_APP/Contents/MacOS/$APP_NAME" ] && \
     pgrep -f "$INSTALLED_APP/Contents/MacOS/$APP_NAME" >/dev/null; then
    local previous
    previous=$("$INSTALLED_APP/Contents/MacOS/$APP_NAME" --version)
    if [ "$previous" = "f50-dashboard 0.1.0" ] && [ ! -f "$SUPPORT/state.json" ]; then
      fail "旧版累计尚未保存，请先在菜单点击「退出」，再运行 install"
    fi
  fi
  mkdir -p "$INSTALL_DIR" "$SUPPORT" "$HOME/Library/LaunchAgents"
  local staged="$INSTALL_DIR/.$APP_NAME.new.app"
  [ ! -e "$staged" ] || fail "发现未完成的安装目录：$staged，请先检查"
  # 完成复制与签名验证后才停止正在运行的版本。
  cp -R "$APP" "$staged"
  codesign --verify --deep --strict "$staged"
  local backup="$SUPPORT/upgrades/$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$backup"
  [ ! -f "$SUPPORT/config.json" ] || cp -p "$SUPPORT/config.json" "$backup/config.json"
  [ ! -f "$PLIST" ] || cp -p "$PLIST" "$backup/LaunchAgent.plist"
  # 新版通过 SIGTERM 正常保存；停服务后再备份最新累计。
  launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
  local count
  for count in {1..50}; do
    pgrep -f "$INSTALLED_APP/Contents/MacOS/$APP_NAME" >/dev/null || break
    sleep 0.1
  done
  pgrep -f "$INSTALLED_APP/Contents/MacOS/$APP_NAME" >/dev/null && fail "旧进程尚未退出，已停止替换"
  [ ! -f "$SUPPORT/state.json" ] || cp -p "$SUPPORT/state.json" "$backup/state.json"
  [ ! -f "$SUPPORT/state.backup.json" ] || cp -p "$SUPPORT/state.backup.json" "$backup/state.backup.json"
  if [ -d "$INSTALLED_APP" ]; then mv "$INSTALLED_APP" "$backup/previous-installed.app"; fi
  mv "$staged" "$INSTALLED_APP"
  # Python plistlib 正确转义路径中的空格、& 等字符。
  python3 - "$PLIST" "$INSTALLED_APP" "$BUNDLE_ID" "$SUPPORT" <<'PY_PLIST'
import pathlib, plistlib, sys
path, app, label, support = sys.argv[1:]
d = dict(Label=label, ProgramArguments=[app + "/Contents/MacOS/F50Dashboard"],
         RunAtLoad=True, KeepAlive=dict(SuccessfulExit=False),
         LimitLoadToSessionType="Aqua",
         StandardOutPath=support + "/app.stdout.log", StandardErrorPath=support + "/app.stderr.log")
pathlib.Path(path).write_bytes(plistlib.dumps(d))
PY_PLIST
  if ! launchctl bootstrap "gui/$(id -u)" "$PLIST"; then
    # 启动失败时恢复旧 App 和启动配置；保留失败版本供排查。
    launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
    mv "$INSTALLED_APP" "$backup/failed-install.app"
    if [ -d "$backup/previous-installed.app" ]; then mv "$backup/previous-installed.app" "$INSTALLED_APP"; fi
    if [ -f "$backup/LaunchAgent.plist" ]; then
      cp -p "$backup/LaunchAgent.plist" "$PLIST"
      launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || true
    fi
    fail "新版启动失败，已尝试恢复旧版本；请检查 $backup"
  fi
  info "已安装并启动，配置和累计数据已保留；备份：$backup"
}

do_uninstall() {
  launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
  rm -f "$PLIST"
  if [ -d "$INSTALLED_APP" ]; then
    mkdir -p "$SUPPORT/upgrades"
    mv "$INSTALLED_APP" "$SUPPORT/upgrades/uninstalled-$(date '+%Y%m%d-%H%M%S').app"
  fi
  info "已移除开机自启；App、配置与历史数据保留在 $SUPPORT"
}

case "${1:-build}" in
  build) do_build ;;
  test) do_test ;;
  install) do_install ;;
  check) "$INSTALLED_APP/Contents/MacOS/$APP_NAME" --check ;;
  uninstall) do_uninstall ;;
  clean) rm -rf "$BUILD_DIR" ;;
  *) echo "用法：$0 {build|test|install|check|uninstall|clean}"; exit 2 ;;
esac
