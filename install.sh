#!/usr/bin/env bash
#
# smon 一键安装脚本
# 用法:  curl -fsSL https://raw.githubusercontent.com/dongdonglog/fast-bash/main/install.sh | sudo bash
set -euo pipefail

BASE_URL="${SMON_BASE_URL:-https://raw.githubusercontent.com/dongdonglog/fast-bash/main}"
MIRROR_URL="${SMON_MIRROR_URL:-https://cdn.jsdelivr.net/gh/dongdonglog/fast-bash@main}"
INSTALL_DIR="${INSTALL_DIR:-}"

# 选择安装目录：优先用户指定，否则按架构选 PATH 中可写的 bin 目录
if [[ -z $INSTALL_DIR ]]; then
  if [[ $(uname -m) == "arm64" ]] && [[ -d /opt/homebrew/bin ]]; then
    INSTALL_DIR="/opt/homebrew/bin"
  else
    INSTALL_DIR="/usr/local/bin"
  fi
fi

if [[ $EUID -ne 0 ]]; then
  echo "需要 root 权限安装到 $INSTALL_DIR，请使用 sudo 运行：" >&2
  echo "  curl -fsSL https://raw.githubusercontent.com/dongdonglog/fast-bash/main/install.sh | sudo bash" >&2
  exit 1
fi

fetch() {  # $1=文件名(如 smon.sh) $2=dest；主源失败自动回退镜像，curl 带重试
  local f=$1 dest=$2 u
  local urls=("$BASE_URL/$f" "$MIRROR_URL/$f")
  for u in "${urls[@]}"; do
    if command -v curl >/dev/null; then
      if curl -fsSL --retry 3 --retry-all-errors --connect-timeout 15 "$u" -o "$dest" 2>/dev/null; then
        return 0
      fi
    elif command -v wget >/dev/null; then
      if wget -qO "$dest" "$u" 2>/dev/null; then
        return 0
      fi
    else
      echo "未找到 curl 或 wget" >&2
      exit 1
    fi
    echo "  [重试] $u 失败，尝试下一个源 ..." >&2
  done
  echo "下载 $f 失败（主源与镜像均不可达）" >&2
  return 1
}

echo "[1/3] 下载 smon 与 web 面板 ..."
fetch "$BASE_URL/smon.sh" "$INSTALL_DIR/smon"
fetch "$BASE_URL/web.py" "$INSTALL_DIR/web.py"

echo "[2/3] 设置可执行权限 ..."
chmod +x "$INSTALL_DIR/smon"

echo "[3/3] 验证 ..."
if bash -n "$INSTALL_DIR/smon" && [[ -x "$INSTALL_DIR/smon" ]] && python3 -c "import ast; ast.parse(open('$INSTALL_DIR/web.py').read())" 2>/dev/null; then
  echo
  echo "✅ 安装成功到 $INSTALL_DIR！"
  if ! command -v smon >/dev/null 2>&1; then
    echo "⚠️  提示：$INSTALL_DIR 不在当前 PATH 中，无法直接使用 smon。"
    echo "   临时生效:  export PATH=\"$INSTALL_DIR:\$PATH\""
    echo "   永久生效:  把上面这行加入 ~/.zshrc 或 ~/.bashrc 后重新打开终端"
    echo
  fi
  echo "直接运行："
  echo "   smon                    # 中文实时进程表"
  echo "   smon -m / -d / -n       # 按内存 / 磁盘IO / 网络 排序"
  echo "   smon -j                 # 输出 JSON"
  echo "   smon --serve             # 启动 Web 面板 http://<ip>:8080/"
  echo "   smon -h                 # 帮助"
else
  echo "❌ 安装失败，校验未通过" >&2
  rm -f "$INSTALL_DIR/smon" "$INSTALL_DIR/web.py"
  exit 1
fi
