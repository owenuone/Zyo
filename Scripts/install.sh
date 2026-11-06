#!/bin/bash
# 字游安装脚本（随 make dist 的压缩包分发）：bash install.sh
set -euo pipefail

dir="$(cd "$(dirname "$0")" && pwd)"
target="$HOME/Library/Input Methods"

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "只支持 Apple Silicon Mac" >&2
    exit 1
fi
major="$(sw_vers -productVersion | cut -d. -f1)"
if ((major < 26)); then
    echo "需要 macOS 26 或以上（当前 $(sw_vers -productVersion)）" >&2
    exit 1
fi

# 从网上或聊天工具收到的文件带隔离标记，ad-hoc 签名的 App 会被 Gatekeeper 拦下
xattr -dr com.apple.quarantine "$dir"

killall Zyo 2>/dev/null || true
mkdir -p "$target"
rm -rf "$target/Zyo.app"
cp -R "$dir/Zyo.app" "$target/"
"$dir/register" "$target/Zyo.app"

cat <<'EOF'

安装完成，接下来：
1. 系统设置 → 键盘 → 输入法 → 编辑 → + → 简体中文 → 字游
2. 系统设置 → 通用 → 语言与地区 → 翻译语言：下载「简体中文」和「英语」
   （也可以在菜单栏输入法图标 → 设置… 里下载）
首次切换到字游时会部署词库，几秒内打字会提示「词库部署中」。
如果输入法列表里找不到字游，注销重新登录一次。
建议在输入法编辑页面关闭「使用大写锁定键切换"ABC"输入法」：开着时长按 Caps Lock 会切到 ABC 并把字游置灰，短按 Caps Lock 关掉大写锁定即可恢复。
EOF
