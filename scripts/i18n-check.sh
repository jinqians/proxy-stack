#!/usr/bin/env bash
# i18n-check.sh — 校验 zh/en 语言表键对齐 + 追踪已迁移文件里的残留中文。
# 纯 bash + coreutils（comm/grep/sort），无外部依赖。
# 退出码：键集合不一致 → 1；一致 → 0（残留中文仅作追踪，不影响退出码）。

set -uo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LANG_ROOT="$PSM_ROOT/lang"

rc=0

# 提取一个语言目录里的全部 MSG[...] 键名（去重排序）。
# 仅匹配真正的赋值行（行首可有缩进 + MSG[...]=），避免误匹配注释里的 MSG[...]。
keys() {
    local lang="$1"
    find "$LANG_ROOT" \( -path "$LANG_ROOT/${lang}.sh" -o -path "$LANG_ROOT/${lang}/*.sh" \) -type f -print0 2>/dev/null \
        | xargs -0 grep -hoE '^[[:space:]]*MSG\[[^]]+\]=' 2>/dev/null \
        | grep -oE 'MSG\[[^]]+\]' \
        | sort -u
}

# 统计文件中「非注释代码」含中日韩统一表意文字（U+4E00–U+9FFF）的行数。
# 开发者注释（整行注释或行尾注释）里的中文是给维护者看的，不属于用户输出，故排除。
# 优先用 perl 做简单注释剥离；缺 perl 时回退到 GNU grep -P（只能排除整行注释）。
cjk_lines() {
    local f="$1"
    if command -v perl >/dev/null 2>&1; then
        perl -CSD -ne 'next if /^\s*#/; s/[[:space:]]+#.*$//; $c++ if /\p{Han}/; END{print $c||0}' "$f" 2>/dev/null
    elif echo | grep -qP '' 2>/dev/null; then
        grep -vP '^[[:space:]]*#' "$f" 2>/dev/null | grep -cP '[\x{4e00}-\x{9fff}]' || true
    else
        echo "?"
    fi
}

echo "== key 对齐 =="
if [[ ! -f "$LANG_ROOT/zh.sh" || ! -f "$LANG_ROOT/en.sh" ]]; then
    echo "  缺少语言表：$LANG_ROOT/zh.sh 或 $LANG_ROOT/en.sh" >&2
    exit 1
fi

missing_en="$(comm -23 <(keys zh) <(keys en))"
missing_zh="$(comm -13 <(keys zh) <(keys en))"

if [[ -n "$missing_en" ]]; then
    echo "en.sh 缺失的键（zh 有 en 无）:"
    echo "$missing_en" | sed 's/^/  /'
    rc=1
fi
if [[ -n "$missing_zh" ]]; then
    echo "zh.sh 缺失的键（en 有 zh 无）:"
    echo "$missing_zh" | sed 's/^/  /'
    rc=1
fi
[[ $rc -eq 0 ]] && echo "  OK：zh/en 键集合一致（$(keys zh | grep -c . ) 个键）"

echo ""
echo "== 源码文件残留中文（非注释行；0 = 该文件所有用户输出已可切换语言）=="
# 自动扫描全部 .sh 并排除：语言表（lang/，本就含中文）、i18n 基建（i18n.sh 内含
# 中英双语选择器、本校验脚本）、.git。已迁移的文件显示 0；逐步归零即迁移完成。
total=0; migrated=0; remaining=""
while IFS= read -r f; do
    total=$((total + 1))
    n="$(cjk_lines "$f")"; n="${n:-0}"
    if [[ "$n" == "0" ]]; then
        migrated=$((migrated + 1))
    else
        remaining+="$(printf '  %-44s %s 行\n' "${f#"$PSM_ROOT"/}" "$n")"$'\n'
    fi
done < <(find "$PSM_ROOT" -name '*.sh' \
            -not -path '*/lang/*' -not -path '*/.git/*' \
            -not -name 'i18n.sh' -not -name 'i18n-check.sh' -not -name 'bootstrap.sh' | sort)
echo "  已迁移（残留 0）：${migrated} / ${total} 个文件"
if [[ -n "$remaining" ]]; then
    echo "  待迁移："
    printf '%s' "$remaining"
fi

exit $rc
