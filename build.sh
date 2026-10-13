#!/bin/bash
# f50-dashboard 构建 / 安装脚本
#
# 用法：
#   ./build.sh             构建到 build/F50Dashboard.app
#   ./build.sh install     构建并安装到 ~/Applications，注册开机自启
#   ./build.sh uninstall   移除 App 与开机自启
#   ./build.sh clean       清理构建产物
#
# 只依赖 Xcode Command Line Tools 自带的 swiftc，无需 Apple 开发者账号，
# 也不需要联网。本地编译的 App 不受 Gatekeeper 拦截。

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="F50Dashboard"
BUNDLE_ID="io.github.nowhere1975.f50dashboard"
VERSION="0.1.0"

BUILD_DIR="$PROJECT_DIR/build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

# ---------- 输出 ----------
c_ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
c_info() { printf '  \033[36m·\033[0m %s\n' "$1"; }
c_err()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; }

require_tools() {
  if ! command -v swiftc >/dev/null 2>&1; then
    c_err "找不到 swiftc。请先安装 Xcode Command Line Tools："
    echo "      xcode-select --install" >&2
    exit 1
  fi
}

# ---------- 构建 ----------
do_build() {
  require_tools
  c_info "swiftc: $(command -v swiftc)"
  c_info "版本:   $VERSION"

  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

  # Info.plist（替换版本占位符）
  sed "s/__VERSION__/$VERSION/g" "$PROJECT_DIR/Resources/Info.plist" \
    > "$APP/Contents/Info.plist"

  # 编译所有源文件
  local sources
  sources=$(find "$PROJECT_DIR/Sources/F50Dashboard" -name '*.swift' | sort)
  c_info "源文件: $(echo "$sources" | wc -l | tr -d ' ') 个"

  # shellcheck disable=SC2086
  if ! swiftc -O -swift-version 5 -framework Cocoa \
        $sources -o "$APP/Contents/MacOS/$APP_NAME" 2>&1; then
    c_err "编译失败"
    exit 1
  fi
  c_ok "编译完成"

  # ad-hoc 签名：让 App 能被正常启动，不需要开发者证书
  codesign --force --deep --sign - "$APP" 2>/dev/null && c_ok "已临时签名" || c_info "签名跳过（不影响本机运行）"

  local size
  size=$(du -sh "$APP" | cut -f1)
  c_ok "产物: $APP  ($size)"
  echo
  c_info "自检（应全部显示 ✅）："
  "$APP/Contents/MacOS/$APP_NAME" --check | sed 's/^/      /' || true
}

# ---------- 安装 ----------
do_install() {
  do_build
  echo
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALLED_APP"
  cp -R "$APP" "$INSTALLED_APP"
  c_ok "已安装到 $INSTALLED_APP"

  # 开机自启：KeepAlive 保证崩溃后自动拉起
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>             <string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALLED_APP/Contents/MacOS/$APP_NAME</string>
    </array>
    <key>RunAtLoad</key>         <true/>
    <key>KeepAlive</key>         <true/>
    <!-- 菜单栏 App 必须在图形登录会话里运行 -->
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST_EOF

  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
  c_ok "已注册开机自启 ($BUNDLE_ID)"
  echo
  c_info "看菜单栏右上角，应该出现 ↓… ↑… 的读数"
  c_info "配置文件: $HOME/Library/Application Support/F50Dashboard/config.json"
}

# ---------- 卸载 ----------
do_uninstall() {
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  c_ok "已移除开机自启"

  pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  rm -rf "$INSTALLED_APP"
  c_ok "已移除 $INSTALLED_APP"

  c_info "配置与历史数据仍保留在 ~/Library/Application Support/F50Dashboard/"
  c_info "如需彻底清除：rm -rf \"$HOME/Library/Application Support/F50Dashboard\""
}

# ---------- 清理 ----------
do_clean() {
  rm -rf "$BUILD_DIR"
  c_ok "已清理 $BUILD_DIR"
}

case "${1:-build}" in
  build)     do_build ;;
  install)   do_install ;;
  uninstall) do_uninstall ;;
  clean)     do_clean ;;
  *) echo "用法: $0 {build|install|uninstall|clean}"; exit 2 ;;
esac
