#!/bin/bash
# 把 librime 官方发布版及其插件拷进 App 的 Contents/Frameworks，改为 @rpath 引用并重新签名。
# 官方版依赖已静态链接、最低 macOS 10.15；Homebrew 版只支持打包机的系统版本，所以分发不用它
# 用法：Scripts/bundle_dylibs.sh <App 路径> <官方 librime 的 lib 目录>
set -euo pipefail

app="$1"
rime_lib="$2"
exe="$app/Contents/MacOS/Zyo"
frameworks="$app/Contents/Frameworks"
plugins="$frameworks/rime-plugins"

mkdir -p "$plugins"
# 官方包是 universal，App 只支持 Apple Silicon
lipo "$rime_lib/librime.1.dylib" -thin arm64 -output "$frameworks/librime.1.dylib"
for source in "$rime_lib"/rime-plugins/*.dylib; do
    plugin="$plugins/$(basename "$source")"
    lipo "$source" -thin arm64 -output "$plugin"
    # 插件按 @rpath 引用 librime，自身没有 rpath
    install_name_tool -add_rpath "@loader_path/.." "$plugin" 2>/dev/null
done

# 开发版链接的是 Homebrew 的 librime
old="$(otool -L "$exe" | awk '/librime/{print $1}')"
install_name_tool -change "$old" "@rpath/librime.1.dylib" "$exe" 2>/dev/null
install_name_tool -add_rpath "@executable_path/../Frameworks" "$exe" 2>/dev/null

# install_name_tool 会使原签名失效，先签各个 dylib 再签整个 App
find "$frameworks" -name '*.dylib' -exec codesign --force --sign - {} \;
codesign --force --sign - "$app"

files=("$exe" "$frameworks"/*.dylib "$plugins"/*.dylib)
if otool -L "${files[@]}" | grep -q /opt/homebrew; then
    echo "仍有指向 /opt/homebrew 的引用：" >&2
    otool -L "${files[@]}" | grep -B20 /opt/homebrew >&2
    exit 1
fi
echo "已打包 $(ls "$frameworks"/*.dylib "$plugins"/*.dylib | wc -l | tr -d ' ') 个 dylib"
