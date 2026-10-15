#!/bin/bash
# 只打包构建产物；不读取用户配置、历史或日志。
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$PROJECT_DIR/build/F50Dashboard.app"
PLIST="$APP/Contents/Info.plist"
OUTPUT="$PROJECT_DIR/build/releases"
fail() { printf '打包失败：%s\n' "$1" >&2; exit 1; }

[ -x "$APP/Contents/MacOS/F50Dashboard" ] || fail "请先运行 ./build.sh"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "版本号无效"
ARCH=$(/usr/bin/lipo -archs "$APP/Contents/MacOS/F50Dashboard")
[ "$ARCH" = arm64 ] || fail "当前下载包仅发布 Apple Silicon 版，实际架构：$ARCH"
[ "$("$APP/Contents/MacOS/F50Dashboard" --version)" = "Traffic Monitor $VERSION" ] || fail "程序版本与 Info.plist 不一致"
/usr/bin/codesign --verify --deep --strict "$APP"

NAME="Traffic-Monitor-$VERSION-macos-$ARCH.dmg"
mkdir -p "$OUTPUT"
[ ! -e "$OUTPUT/$NAME" ] || fail "文件已存在：$OUTPUT/${NAME}；请先另行保存旧包"
[ ! -e "$OUTPUT/$NAME.sha256" ] || fail "校验文件已存在"
STAGE=$(mktemp -d "$OUTPUT/.package.XXXXXX")
MOUNTED=false
cleanup() {
  if [ "$MOUNTED" = true ]; then /usr/bin/hdiutil detach "$STAGE/mounted" >/dev/null || true; fi
  rm -rf "$STAGE"
}
trap cleanup EXIT
VOLUME="$STAGE/volume"
PACKAGED_APP="$VOLUME/F50Dashboard.app"
mkdir -p "$PACKAGED_APP/Contents/MacOS" "$PACKAGED_APP/Contents/Resources"
# 白名单复制，避免构建目录内的临时文件、扩展属性进入公开包。
/usr/bin/install -m 644 "$PLIST" "$PACKAGED_APP/Contents/Info.plist"
/usr/bin/install -m 755 "$APP/Contents/MacOS/F50Dashboard" "$PACKAGED_APP/Contents/MacOS/F50Dashboard"
/usr/bin/codesign --force --sign - "$PACKAGED_APP"
/usr/bin/codesign --verify --deep --strict "$PACKAGED_APP"
/usr/bin/install -m 644 "$PROJECT_DIR/docs/INSTALL.txt" "$VOLUME/安装说明.txt"
/usr/bin/install -m 644 "$PROJECT_DIR/LICENSE" "$VOLUME/LICENSE.txt"
ln -s /Applications "$VOLUME/Applications"

/usr/bin/hdiutil create -volname "Traffic Monitor $VERSION" -srcfolder "$VOLUME" \
  -fs HFS+ -format UDZO "$STAGE/$NAME" >/dev/null
/usr/bin/hdiutil verify "$STAGE/$NAME" >/dev/null
mkdir "$STAGE/mounted"
/usr/bin/hdiutil attach "$STAGE/$NAME" -readonly -nobrowse -noautoopen \
  -mountpoint "$STAGE/mounted" >/dev/null
MOUNTED=true
ROUNDTRIP="$STAGE/mounted/F50Dashboard.app"
/usr/bin/codesign --verify --deep --strict "$ROUNDTRIP"
cmp "$PACKAGED_APP/Contents/MacOS/F50Dashboard" "$ROUNDTRIP/Contents/MacOS/F50Dashboard"
[ "$("$ROUNDTRIP/Contents/MacOS/F50Dashboard" --version)" = "Traffic Monitor $VERSION" ] || fail "挂载后版本验证失败"
[ "$(readlink "$STAGE/mounted/Applications")" = /Applications ] || fail "应用程序快捷方式无效"
/usr/bin/hdiutil detach "$STAGE/mounted" >/dev/null
MOUNTED=false
mv "$STAGE/$NAME" "$OUTPUT/$NAME"
(cd "$OUTPUT" && /usr/bin/shasum -a 256 "$NAME" > "$NAME.sha256")
printf '已打包并验证：%s\n' "$OUTPUT/$NAME"
