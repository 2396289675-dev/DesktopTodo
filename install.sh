#!/bin/zsh
# DesktopTodo 一键安装：自动探测可用 SDK → 编译 → 打包 → 装到 /Applications
# 用法：解压后在文件夹里执行  ./install.sh
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="DesktopTodo"
DEST="/Applications/$APP_NAME.app"
BUILD="$(mktemp -d)/$APP_NAME.app"
ARCH="$(uname -m)"

echo "== 检查编译环境"
if ! command -v swiftc >/dev/null 2>&1; then
    echo "没有找到 swiftc。请先安装 Xcode 命令行工具："
    echo "    xcode-select --install"
    echo "装完重新运行本脚本。"
    exit 1
fi

echo "== 探测可用的 macOS SDK"
SDK=""
for s in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | sort -r) \
         $(ls -d /Applications/Xcode*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.sdk 2>/dev/null | sort -r); do
    if swiftc -sdk "$s" -typecheck -target "${ARCH}-apple-macosx13.0" "$ROOT/src/main.swift" >/dev/null 2>&1; then
        SDK="$s"; break
    fi
done
if [ -z "$SDK" ]; then
    echo "找不到与当前 swiftc 版本匹配的 SDK。"
    echo "请升级 Xcode 命令行工具：  softwareupdate --install -a"
    exit 1
fi
echo "   使用 SDK: $SDK"
echo "   架构: $ARCH"

mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"

echo "== 编译"
swiftc -sdk "$SDK" -O -swift-version 5 -strict-concurrency=minimal \
    -target "${ARCH}-apple-macosx13.0" \
    "$ROOT/src/main.swift" -o "$BUILD/Contents/MacOS/$APP_NAME"
cp "$ROOT/Info.plist" "$BUILD/Contents/Info.plist"

echo "== 图标"
swiftc -sdk "$SDK" -O -swift-version 5 -target "${ARCH}-apple-macosx13.0" \
    "$ROOT/src/genicon.swift" -o /tmp/genicon_$$ 2>/dev/null
/tmp/genicon_$$ /tmp/icon1024_$$.png
ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s /tmp/icon1024_$$.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1
    d=$((s*2)); sips -z $d $d /tmp/icon1024_$$.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
done
iconutil -c icns "$ICONSET" -o "$BUILD/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" /tmp/genicon_$$ /tmp/icon1024_$$.png

echo "== 签名并安装"
codesign --force --deep --sign - "$BUILD" 2>/dev/null || true
killall "$APP_NAME" 2>/dev/null || true
rm -rf "$DEST"
cp -R "$BUILD" "$DEST"
rm -rf "$(dirname "$BUILD")"

printf "\n是否开机自动启动？(y/n) "
read -r ans
if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
    "$DEST/Contents/MacOS/$APP_NAME" --login-on
fi

echo "== 启动"
open -a "$DEST"
echo
echo "完成：$DEST"
echo "菜单栏右侧的 ✓ 图标是设置入口（左键设置，右键快捷菜单）。"
