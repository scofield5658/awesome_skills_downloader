#!/usr/bin/env bash
# Linux / macOS：在 git 被管控、无法 git clone 的内网里，用系统 curl 走 HTTP
# 一次性下载 GitHub 默认分支 zip（等同网页 Code -> Download ZIP），再解压整理
# 成工作区目录。全程不调用 git，也不创建 .git。
#
# 结果：<项目根>/output/{groupName}-{repoName}/
# 例如 vercel-labs/skills -> output/vercel-labs-skills
# 代理：curl 会读取 HTTP_PROXY / HTTPS_PROXY / NO_PROXY。
#
# 用法：
#   ./download-repos.sh
#   OUTPUT_DIR=/tmp/output ./download-repos.sh
#   DRY_RUN=1 ./download-repos.sh
#   GITHUB_TOKEN=ghp_xxx ./download-repos.sh   # 私有仓或提高 API 限额时可选
#
# 依赖：curl。解压需要 unzip 或 python3。

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LIST_FILE="${REPOS_FILE:-$SCRIPT_DIR/repos.txt}"
OUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/output}"
USER_AGENT="${USER_AGENT:-awesome-skills-downloader}"
DRY_RUN="${DRY_RUN:-0}"

if ! command -v curl >/dev/null 2>&1; then
  echo "[ERROR] 未找到 curl，请先安装。" >&2
  exit 1
fi

if [ ! -f "$LIST_FILE" ]; then
  echo "[ERROR] 找不到仓库列表：$LIST_FILE" >&2
  exit 1
fi

trim() {
  printf '%s' "$1" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# 将多种 GitHub 地址解析为 "owner repo"
parse_owner_repo() {
  raw=$(trim "$1")
  [ -z "$raw" ] && return 1

  raw="${raw%.git}"
  raw="${raw%/}"

  case "$raw" in
    git@github.com:*)
      raw="${raw#git@github.com:}"
      ;;
    ssh://git@github.com/*)
      raw="${raw#ssh://git@github.com/}"
      ;;
    *github.com/*)
      raw="${raw#*github.com/}"
      ;;
  esac

  case "$raw" in
    */*) ;;
    *) return 1 ;;
  esac

  owner=$(printf '%s' "$raw" | cut -d/ -f1)
  repo=$(printf '%s' "$raw" | cut -d/ -f2)
  repo="${repo%.git}"

  if [ -z "$owner" ] || [ -z "$repo" ]; then
    return 1
  fi
  printf '%s %s\n' "$owner" "$repo"
}

is_zip_file() {
  hex=$(dd if="$1" bs=2 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$hex" = "504b" ]
}

extract_zip() {
  zip_path="$1"
  extract_dir="$2"

  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$zip_path" -d "$extract_dir"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$zip_path" "$extract_dir"
  else
    echo "[ERROR] 需要 unzip 或 python3 才能解压。" >&2
    return 1
  fi
}

# 将 zip 整理成 dest 下的仓库工作区：去掉 GitHub 自动加的顶层包装目录。
materialize_repo() {
  zip_path="$1"
  dest="$2"
  work=$(mktemp -d "${TMPDIR:-/tmp}/skills-dl.XXXXXX")
  extract_dir="$work/extract"
  mkdir -p "$extract_dir"

  if ! extract_zip "$zip_path" "$extract_dir"; then
    rm -rf "$work"
    return 1
  fi

  src="$extract_dir"
  only=""
  count=0
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    count=$((count + 1))
    only="$entry"
  done <<EOF
$(find "$extract_dir" -mindepth 1 -maxdepth 1)
EOF

  if [ "$count" -eq 1 ] && [ -d "$only" ]; then
    src="$only"
  fi

  rm -rf "$dest"
  mkdir -p "$dest"
  if ! cp -R "$src/." "$dest/"; then
    rm -rf "$work" "$dest"
    return 1
  fi

  rm -rf "$work"
}

ok_count=0
fail_count=0

mkdir -p "$OUT_DIR"

while IFS= read -r line || [ -n "$line" ]; do
  line=$(trim "$line")
  case "$line" in
    ""|\#*) continue ;;
  esac

  if ! parsed=$(parse_owner_repo "$line"); then
    echo "[FAIL] 无法解析：$line" >&2
    fail_count=$((fail_count + 1))
    continue
  fi

  owner=$(printf '%s' "$parsed" | cut -d' ' -f1)
  repo=$(printf '%s' "$parsed" | cut -d' ' -f2)
  dest="$OUT_DIR/${owner}-${repo}"

  if [ -n "${GITHUB_TOKEN:-}" ]; then
    url="https://api.github.com/repos/${owner}/${repo}/zipball"
    auth_note="API zipball"
  else
    url="https://github.com/${owner}/${repo}/archive/HEAD.zip"
    auth_note="archive/HEAD.zip"
  fi

  echo "[INFO] $owner/$repo  ->  $dest  ($auth_note)"

  if [ "$DRY_RUN" != "0" ]; then
    echo "       $url"
    ok_count=$((ok_count + 1))
    continue
  fi

  zip_path=$(mktemp "${TMPDIR:-/tmp}/skills-dl.XXXXXX.zip")
  curl_args=(-fL --retry 3 --retry-delay 2 -A "$USER_AGENT" -o "$zip_path" -- "$url")
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl_args=(-H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "${curl_args[@]}")
  fi

  if ! curl "${curl_args[@]}"; then
    echo "[FAIL] 下载失败：$owner/$repo" >&2
    rm -f "$zip_path"
    fail_count=$((fail_count + 1))
    continue
  fi

  if ! is_zip_file "$zip_path"; then
    echo "[FAIL] 下载结果不是 zip：$owner/$repo" >&2
    rm -f "$zip_path"
    fail_count=$((fail_count + 1))
    continue
  fi

  if command -v unzip >/dev/null 2>&1; then
    if ! unzip -tqq "$zip_path"; then
      echo "[FAIL] zip 校验失败：$owner/$repo" >&2
      rm -f "$zip_path"
      fail_count=$((fail_count + 1))
      continue
    fi
  fi

  if ! materialize_repo "$zip_path" "$dest"; then
    echo "[FAIL] 解压整理失败：$owner/$repo" >&2
    rm -f "$zip_path"
    fail_count=$((fail_count + 1))
    continue
  fi

  rm -f "$zip_path"
  echo "[OK]   $dest"
  ok_count=$((ok_count + 1))
done < "$LIST_FILE"

echo
echo "完成：成功 $ok_count，失败 $fail_count"
if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
