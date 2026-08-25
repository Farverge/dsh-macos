#!/bin/bash
# DSH Desktop 一键安装脚本
#
# 用法（README 展示的一行命令）：
#   curl -fsSL https://raw.githubusercontent.com/Farverge/DSH-MacOS/main/install.sh | bash
#
# 行为：查询 GitHub Releases 最新版 → 下载资产包 → 安装到 /Applications
#      （无权限时回退 ~/Applications）→ 启动应用。
# 说明：curl 下载的文件不带隔离标记，Gatekeeper 不介入，无需任何签名证书。
# 前提：macOS 13+；应用运行需要 Node.js（终端 `node -v` 有输出）。
set -euo pipefail

REPO="Farverge/DSH-MacOS"
APP_NAME="DSH Desktop.app"
# 发版约定：每个 Release 附带此命名的 zip（内含根级 DSH Desktop.app）。
# 注意：GitHub 会把资产名中的空格替换为点号，故约定直接使用点号命名，
# 与 Releases 页面展示名一致，无需任何 URL 编码。
ASSET="DSH.MacOS.Desktop.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> 查询最新版本…"
URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"
echo "    ${URL}"

echo "==> 下载…"
curl -fSL --progress-bar -o "${TMP}/${ASSET}" "$URL"

echo "==> 解压…"
unzip -q -o "${TMP}/${ASSET}" -d "$TMP"

if [ ! -d "${TMP}/${APP_NAME}" ]; then
  echo "!! 资产包结构不符合预期（未找到 ${APP_NAME}），请到 Releases 页面手动下载。" >&2
  exit 1
fi

echo "==> 安装…"
DEST="/Applications"
if ! mkdir -p "$DEST" 2>/dev/null || [ ! -w "$DEST" ]; then
  DEST="${HOME}/Applications"
  mkdir -p "$DEST"
  echo "    /Applications 不可写，改安装到 ${DEST}"
fi
rm -rf "${DEST}/${APP_NAME}"
ditto "${TMP}/${APP_NAME}" "${DEST}/${APP_NAME}"

echo "==> 启动…"
open "${DEST}/${APP_NAME}"

cat <<EOF

✅ 安装完成：${DEST}/${APP_NAME}

后续提示：
· 关闭窗口 ≠ 退出（Dock 常驻）；彻底退出用 Cmd+Q
· 应用会自动拉起 dsh 后端（127.0.0.1:3080）
· 运行需要 Node.js；未安装时请先执行：brew install node
· 升级：重新运行本命令，或到 Releases 页面下载覆盖
EOF
