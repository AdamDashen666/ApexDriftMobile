#!/usr/bin/env bash
# 可选：让 CI 用你自己的安卓证书签名（这样每次构建签名都一样，可以直接覆盖安装）。
# 由你自己在 Git Bash 里运行；脚本只把证书和密码写进 GitHub 仓库的 Actions secrets，不会提交到仓库、也不会上传别处。
#
# 用法:
#   bash scripts/set-android-signing.sh <密钥库文件> <别名>   用已有的密钥库（.jks / .keystore）
#   bash scripts/set-android-signing.sh --new <密钥库文件> <别名>   先用 keytool 新建一个，再设置
#   bash scripts/set-android-signing.sh --remove                  删掉这三个 secrets，回到每次临时调试签名
#
# 会设置三个 secrets：ANDROID_KEYSTORE_BASE64、ANDROID_KEYSTORE_PASSWORD、ANDROID_KEY_ALIAS。
# 注意：
# - Godot 只接收一个密码，密钥（key）密码必须和密钥库（store）密码相同；PKCS12 格式本来就是同一个。
# - 密钥库文件自己备份好、别放进仓库目录（.gitignore 已排除 *.jks / *.keystore）。丢了就再也发不了能覆盖安装的更新。
# - 换成自己的证书后，手机上先卸载之前用调试签名装的版本，之后就能一直覆盖安装。
set -euo pipefail

GH="${GH:-gh}"
command -v "$GH" >/dev/null 2>&1 || GH="/c/Program Files/GitHub CLI/gh.exe"
cd "$(git rev-parse --show-toplevel)"
REPO="$("$GH" repo view --json nameWithOwner -q .nameWithOwner | tr -d '\r')"

if [ "${1:-}" = "--remove" ]; then
  for s in ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS; do
    "$GH" secret delete "$s" -R "$REPO" || true
  done
  echo "已删除。之后的构建回到每次临时生成调试密钥库签名。"
  exit 0
fi

NEW=0
if [ "${1:-}" = "--new" ]; then NEW=1; shift; fi
KS="${1:-}"
ALIAS="${2:-}"
[ -n "$KS" ] && [ -n "$ALIAS" ] || { sed -n '2,17p' "$0"; exit 1; }
command -v keytool >/dev/null 2>&1 || { echo "找不到 keytool：请先装 JDK 17 并把它的 bin 加到 PATH"; exit 1; }

case "$(cd "$(dirname "$KS")" 2>/dev/null && pwd)/" in
  "$(pwd)"/*) echo "密钥库不要放在仓库目录里：$KS"; exit 1 ;;
esac

read -r -s -p "密钥库密码（至少 6 位）: " PW; echo
[ ${#PW} -ge 6 ] || { echo "密码太短"; exit 1; }

if [ $NEW = 1 ]; then
  [ ! -e "$KS" ] || { echo "$KS 已存在，不覆盖"; exit 1; }
  read -r -s -p "再输一遍: " PW2; echo
  [ "$PW" = "$PW2" ] || { echo "两次不一致"; exit 1; }
  keytool -genkeypair -keystore "$KS" -storetype PKCS12 -alias "$ALIAS" -keyalg RSA -keysize 4096 -validity 10000 \
    -storepass "$PW" -keypass "$PW" -dname "CN=APEX DRIFT"
  echo "已新建 $KS，请立刻备份。"
fi

keytool -list -keystore "$KS" -storepass "$PW" -alias "$ALIAS" >/dev/null || { echo "打不开：密码或别名不对"; exit 1; }

base64 -w0 "$KS" | "$GH" secret set ANDROID_KEYSTORE_BASE64 -R "$REPO"
printf '%s' "$PW" | "$GH" secret set ANDROID_KEYSTORE_PASSWORD -R "$REPO"
printf '%s' "$ALIAS" | "$GH" secret set ANDROID_KEY_ALIAS -R "$REPO"
unset PW PW2
echo "已设置 $REPO 的签名 secrets。下次带 [apk] 的推送或手动触发就会用这个证书签名。"
