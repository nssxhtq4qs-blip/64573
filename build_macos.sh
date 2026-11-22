#!/bin/bash
# macOS / GitHub Actions 版构建：直接用 Xcode 自带的 clang + ld64 出 arm64e。
# Linux 那套 theos clang-11 + ld64-609 做不到真正的 arm64e（PAC/链式修复），
# 而 Xcode 的 arm64e 是 Apple 自己的 ABI v2 实现，设备上能直接跑。
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/src"
ARCH="${ARCH:-arm64e}"
OUT="${OUT:-dist/AppDump-$ARCH.ipa}"
APP="appdump"
MIN_IOS="15.0"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos -f clang)"
LDID="${LDID:-$(command -v ldid || true)}"

BUILD="$SRC/build-$ARCH"
APP_DIR="$BUILD/Payload/$APP.app"
rm -rf "$BUILD"; mkdir -p "$APP_DIR/Frameworks"

SRCS=$(cd "$SRC" && cat <<'LIST'
main.m
FileManager.m
Exploit.m
ProcessListViewController.m
kexploit/darksword.m
kexploit/offsets.m
kexploit/utils.m
kexploit/persistence.m
kexploit/decrypt.m
kexploit/cyvm.m
kexploit/cydecrypt.m
kexploit/kcblock.m
kexploit/TaskRop/RemoteCall.m
kexploit/TaskRop/thread.m
kexploit/TaskRop/vm.m
kexploit/TaskRop/pac.m
kexploit/TaskRop/exc.m
kexploit/TaskRop/findcachedataoff.m
kexploit/pe/sbx.m
kexploit/pe/vfs.m
kexploit/pe/apfs.m
kexploit/cyremote.m
LIST
)
SRCS="$SRCS $(cd "$SRC/app" && ls *.m | tr '\n' ' ')"

CFLAGS=(-target "$ARCH-apple-ios$MIN_IOS" -isysroot "$SDK" -miphoneos-version-min=$MIN_IOS
        -fobjc-arc -fmodules -O2 -Wno-everything
        -I"$SRC" -I"$SRC/compat" -I"$SRC/kexploit" -I"$SRC/kexploit/cy"
        -I"$SRC/kexploit/pe" -I"$SRC/kexploit/TaskRop" -I"$SRC/kexploit/headers"
        -I"$SRC/kexploit/xpc" -I"$SRC/app")

OBJS=()
cd "$SRC"
for s in $SRCS; do
  o="$BUILD/$(echo "$s" | tr '/' '_' | sed 's/\.m$/.o/')"
  "$CLANG" "${CFLAGS[@]}" -c "$s" -o "$o"
  OBJS+=("$o")
done

"$CLANG" -target "$ARCH-apple-ios$MIN_IOS" -isysroot "$SDK" "${OBJS[@]}" \
  -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
  -framework WebKit -framework AVFoundation -framework AVKit -framework Security \
  -L"$SRC/kexploit/lib" -lxpf -lgrabkernel2 -lz \
  -Wl,-rpath,@executable_path/Frameworks -o "$APP_DIR/$APP"

cp "$SRC/Info.plist" "$APP_DIR/Info.plist"
cp "$SRC/kexploit/lib/libxpf.dylib" "$SRC/kexploit/lib/libgrabkernel2.dylib" "$APP_DIR/Frameworks/" 2>/dev/null || true
cp -R "$SRC/locales/"*.lproj "$APP_DIR/" 2>/dev/null || true
cp "$SRC/LaunchScreen.storyboard" "$APP_DIR/" 2>/dev/null || true

if [ -n "$LDID" ]; then
  "$LDID" -S"$SRC/appdump.entitlements" "$APP_DIR/$APP"
  for d in "$APP_DIR/Frameworks/"*.dylib; do [ -f "$d" ] && "$LDID" -S "$d"; done
fi

mkdir -p "$(dirname "$OUT")"
(cd "$BUILD" && zip -qry "$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")" Payload)
shasum -a 256 "$OUT"
