#!/usr/bin/env bash
# 一键编译：同时产出 rootless 与 rootful 两个 deb
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# ---------- 定位 Theos ----------
if [ -z "${THEOS:-}" ]; then
    if [ -d "$HOME/theos" ]; then
        export THEOS="$HOME/theos"
    elif [ -d "/opt/theos" ]; then
        export THEOS="/opt/theos"
    elif [ -d "/usr/local/theos" ]; then
        export THEOS="/usr/local/theos"
    else
        echo "× 找不到 Theos"
        echo "  先看 README 的「准备编译环境」一节装一下，装完再来。"
        exit 1
    fi
fi

export PATH="$THEOS/bin:$PATH"
echo "→ Theos: $THEOS"

# ---------- 环境自检 ----------
if ! command -v make >/dev/null 2>&1; then
    echo "× 缺少 make"; exit 1
fi

if [ ! -d "$THEOS/sdks" ] || [ -z "$(ls -A "$THEOS/sdks" 2>/dev/null)" ]; then
    echo "× $THEOS/sdks 里没有 iOS SDK"
    echo "  把 iPhoneOS*.sdk 放进去再试（README 有下载地址）"
    exit 1
fi

echo "→ 可用 SDK:"
ls "$THEOS/sdks"

mkdir -p packages

# ---------- 1. rootless ----------
echo ""
echo "=============================================="
echo " 编译 rootless 包（Dopamine / palera1n rootless / 多数 iOS 15-18）"
echo "=============================================="
make clean >/dev/null 2>&1 || true
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless

# ---------- 2. rootful ----------
echo ""
echo "=============================================="
echo " 编译 rootful 包（palera1n 老模式 / checkra1n 类）"
echo "=============================================="
make clean >/dev/null 2>&1 || true
make package FINALPACKAGE=1

echo ""
echo "=============================================="
echo " 编完了，产物在 packages/"
echo "=============================================="
ls -lh packages/*.deb
