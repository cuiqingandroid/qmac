#!/bin/bash
# 把 SwiftPM 产物组装成 qmac.app，并生成 zip / dmg。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP_NAME="qmac"
VERSION="1.0.2"
BUNDLE_ID="com.cuiqing.qmac"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

# 通用二进制：Apple Silicon + Intel。
# 只出 arm64 的话，Intel Mac 上会报「这台 Mac 不支持此应用程序」。
# swift build --arch 需要完整 Xcode（xcbuild），只有 Command Line Tools 时
# 只能分别指定 target 编两次，再用 lipo 合并。
echo "==> 编译 arm64（release，-Osize 体积优先）"
swift build -c release -Xswiftc -Osize -Xswiftc -target -Xswiftc arm64-apple-macos13.0
BIN_ARM="$(swift build -c release --show-bin-path)/$APP_NAME"

echo "==> 编译 x86_64"
swift build -c release --scratch-path .build-x86 -Xswiftc -Osize \
    -Xswiftc -target -Xswiftc x86_64-apple-macos13.0
BIN_X86="$(swift build -c release --scratch-path .build-x86 --show-bin-path)/$APP_NAME"

echo "==> 合并为通用二进制"
mkdir -p "$DIST"
BIN="$DIST/$APP_NAME-universal"
lipo -create "$BIN_ARM" "$BIN_X86" -output "$BIN"
lipo -archs "$BIN" | sed 's/^/   架构: /'

echo "==> 组装 .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
strip -rSTx "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
rm -f "$BIN"

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
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSHumanReadableCopyright</key><string>qmac</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# 有 Developer ID 证书就正式签名 + 公证，没有就退回 ad-hoc 临时签名。
# 只有经过公证的包，用户下载后才不会看到「来源不明」。
# 注意：grep 找不到证书会返回 1，配合 set -e 会让整个脚本静默退出，所以要 || true
IDENTITY="${QMAC_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)}"
NOTARY_PROFILE="${QMAC_NOTARY_PROFILE:-AC_PASSWORD}"
NOTARIZED=0

if [ -n "$IDENTITY" ]; then
    echo "==> 正式签名：$IDENTITY"
    codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"

    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "==> 提交公证（可能要等几分钟）"
        ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
        if xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait; then
            xcrun stapler staple "$APP" && NOTARIZED=1
        else
            echo "   ! 公证失败，产物仍可用但用户会看到来源提示"
        fi
        rm -f "$DIST/notarize.zip"
    else
        echo "   ! 没有公证凭据，跳过公证。先跑一次："
        echo "     xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <你的AppleID> --team-id <TeamID> --password <应用专用密码>"
    fi
else
    echo "==> 临时签名（ad-hoc）——没有 Developer ID 证书，用户下载后会看到「来源不明」"
    codesign --force --deep --sign - "$APP"
fi

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

if [ "$NOTARIZED" = "1" ]; then
    xcrun stapler staple "$DIST/$APP_NAME-$VERSION.dmg" >/dev/null 2>&1 && echo "==> dmg 已装订公证票据"
fi

echo
echo "==> 完成"
du -sh "$APP" | sed 's/^/  .app   /'
du -h "$DIST/$APP_NAME-$VERSION.zip" | sed 's/^/  zip    /'
du -h "$DIST/$APP_NAME-$VERSION.dmg" | sed 's/^/  dmg    /'
echo "  可执行文件 $(du -h "$APP/Contents/MacOS/$APP_NAME" | cut -f1) （$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")）"
