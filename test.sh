#!/bin/bash
# 运行单元测试（Swift Testing 框架）
# - 用 DEVELOPER_DIR 指向 Xcode 工具链（TestingMacros 宏插件只在 Xcode 里有）
# - 用独立 scratch 目录，避免与 build.sh 的 .build 目录冲突
set -euo pipefail
cd "$(dirname "$0")"

XCODE_DEV="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [ ! -d "$XCODE_DEV" ]; then
  echo "✗ 找不到 Xcode 工具链：$XCODE_DEV（Swift Testing 需要 Xcode 的宏插件）" >&2
  exit 1
fi

echo "▸ 运行单元测试（Swift Testing）..."
DEVELOPER_DIR="$XCODE_DEV" swift test --scratch-path .build-tests "$@"
