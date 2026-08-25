#!/bin/bash
# 把 SwiftPM 产物组装成 QuickKit.app，并生成 zip / dmg。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP_NAME="QuickKit"
VERSION="1.0.0"
BUNDLE_ID="com.cuiqing.quickkit"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> 编译（release，-Osize 体积优先）"
swift build -c release -Xswiftc -Osize
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

echo "==> 组装 .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
strip -rSTx "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true

echo "==> 生成图标"
python3 scripts/make-icon.py
ICONSET="$DIST/$APP_NAME.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
cp assets/icon_16.png    "$ICONSET/icon_16x16.png"
cp assets/icon_32.png    "$ICONSET/icon_16x16@2x.png"
cp assets/icon_32.png    "$ICONSET/icon_32x32.png"
cp assets/icon_64.png    "$ICONSET/icon_32x32@2x.png"
cp assets/icon_128.png   "$ICONSET/icon_128x128.png"
cp assets/icon_256.png   "$ICONSET/icon_128x128@2x.png"
cp assets/icon_256.png   "$ICONSET/icon_256x256.png"
cp assets/icon_512.png   "$ICONSET/icon_256x256@2x.png"
cp assets/icon_512.png   "$ICONSET/icon_512x512.png"
cp assets/icon_1024.png  "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/$APP_NAME.icns"
rm -rf "$ICONSET"

echo "==> 打包捐赠二维码"
for code in donate-wechat donate-alipay; do
    if [ -f "assets/$code.png" ]; then
        cp "assets/$code.png" "$APP/Contents/Resources/"
    else
        echo "   ! 缺 assets/$code.png，App 内的打赏页会显示占位框"
    fi
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>        <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSHumanReadableCopyright</key><string>QuickKit</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 临时签名（ad-hoc）"
codesign --force --deep --sign - "$APP"

echo "==> 打包"
rm -f "$DIST/$APP_NAME-$VERSION.zip" "$DIST/$APP_NAME-$VERSION.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$APP_NAME-$VERSION.zip"

STAGE="$DIST/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format ULFO \
    "$DIST/$APP_NAME-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"

echo
echo "==> 完成"
du -sh "$APP" | sed 's/^/  .app   /'
du -h "$DIST/$APP_NAME-$VERSION.zip" | sed 's/^/  zip    /'
du -h "$DIST/$APP_NAME-$VERSION.dmg" | sed 's/^/  dmg    /'
echo "  可执行文件 $(du -h "$APP/Contents/MacOS/$APP_NAME" | cut -f1)"
