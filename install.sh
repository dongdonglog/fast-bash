#!/usr/bin/env bash
#
# smon 安装脚本。离线包中直接运行；通过 curl 运行时下载对应架构的发布包。
set -euo pipefail

BASE_URL="${SMON_BASE_URL:-https://github.com/dongdonglog/fast-bash/releases/latest/download}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
SCRIPT_SOURCE=${BASH_SOURCE[0]-}
SCRIPT_DIR=""
if [[ -n $SCRIPT_SOURCE ]]; then
  SCRIPT_DIR=$(dirname "$SCRIPT_SOURCE")
  if ! SCRIPT_DIR=$(cd "$SCRIPT_DIR" 2>/dev/null && pwd); then SCRIPT_DIR=""; fi
fi
WORK_DIR=""

cleanup() {
  [[ -z $WORK_DIR ]] || rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [[ $EUID -ne 0 ]]; then
  echo "需要 root 权限安装到 $INSTALL_DIR，请使用 sudo 运行" >&2
  exit 1
fi
if [[ $(uname -s) != Linux ]]; then
  echo "smon 0.5 的完整安装包仅支持 Linux amd64/arm64" >&2
  exit 1
fi

case $(uname -m) in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "不支持的架构: $(uname -m)" >&2; exit 1 ;;
esac

fetch() {  # $1=url $2=dest
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 10 "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$2" "$1"
  else
    echo "未找到 curl 或 wget" >&2
    exit 1
  fi
}

SOURCE_DIR=$SCRIPT_DIR
SMON_SOURCE=""
LOCAL_ASSETS_COMPLETE=false
if [[ -n $SOURCE_DIR ]]; then
  SMON_SOURCE="$SOURCE_DIR/smon"
  [[ -f $SMON_SOURCE ]] || SMON_SOURCE="$SOURCE_DIR/smon.sh"
  if [[ -f $SMON_SOURCE && -x $SOURCE_DIR/smon-net && -f $SOURCE_DIR/web.py && \
        -f $SOURCE_DIR/LICENSE && -f $SOURCE_DIR/THIRD_PARTY_NOTICES ]]; then
    LOCAL_ASSETS_COMPLETE=true
  fi
fi
if [[ $LOCAL_ASSETS_COMPLETE != true ]]; then
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/smon-install.XXXXXX")
  ARCHIVE="smon-linux-$ARCH.tar.gz"
  echo "本地资产不完整，下载 $ARCHIVE ..."
  fetch "$BASE_URL/$ARCHIVE" "$WORK_DIR/$ARCHIVE"
  fetch "$BASE_URL/$ARCHIVE.sha256" "$WORK_DIR/$ARCHIVE.sha256"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$WORK_DIR" && sha256sum -c "$ARCHIVE.sha256")
  elif command -v shasum >/dev/null 2>&1; then
    expected=$(awk '{print $1}' "$WORK_DIR/$ARCHIVE.sha256")
    actual=$(shasum -a 256 "$WORK_DIR/$ARCHIVE" | awk '{print $1}')
    [[ $actual == "$expected" ]] || { echo "SHA-256 校验失败" >&2; exit 1; }
  else
    echo "缺少 sha256sum 或 shasum，无法校验安装包" >&2
    exit 1
  fi
  tar -xzf "$WORK_DIR/$ARCHIVE" -C "$WORK_DIR"
  SOURCE_DIR="$WORK_DIR/smon-linux-$ARCH"
  SMON_SOURCE="$SOURCE_DIR/smon"
fi

for required in "$SMON_SOURCE" "$SOURCE_DIR/smon-net" "$SOURCE_DIR/web.py" \
  "$SOURCE_DIR/LICENSE" "$SOURCE_DIR/THIRD_PARTY_NOTICES"; do
  [[ -f $required ]] || { echo "安装包缺少: $required" >&2; exit 1; }
done

DOC_DIR="${SMON_DOC_DIR:-$(dirname "$INSTALL_DIR")/share/doc/smon}"
install -d -m 0755 "$INSTALL_DIR" "$DOC_DIR"
install -m 0755 "$SMON_SOURCE" "$INSTALL_DIR/smon"
install -m 0755 "$SOURCE_DIR/smon-net" "$INSTALL_DIR/smon-net"
install -m 0644 "$SOURCE_DIR/web.py" "$INSTALL_DIR/smon-web.py"
install -m 0644 "$SOURCE_DIR/LICENSE" "$DOC_DIR/LICENSE"
install -m 0644 "$SOURCE_DIR/THIRD_PARTY_NOTICES" "$DOC_DIR/THIRD_PARTY_NOTICES"

bash -n "$INSTALL_DIR/smon"
"$INSTALL_DIR/smon-net" --version >/dev/null
python3 -c "import ast; ast.parse(open('$INSTALL_DIR/smon-web.py', encoding='utf-8').read())"

echo "smon 已安装到 $INSTALL_DIR"
echo "完整进程网络归属请使用: sudo smon 或 sudo smon --serve"
