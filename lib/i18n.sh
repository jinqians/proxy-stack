#!/usr/bin/env bash
# i18n.sh — 轻量纯 Bash 多语言。依赖 common.sh 的 state_get/state_set。

# ── bash 版本检测（关联数组需 bash 4+）─────────────────────────────────────────
# 目标发行版（Ubuntu 20.04+/Debian 10+/EL8+）均满足；仅作友好提示，不硬退出。
[[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] || echo "需要 bash 4+（关联数组） / bash 4+ required (associative arrays)" >&2

declare -gA MSG           # 全局消息表（bash 4+）

PSM_LANG_DEFAULT="zh"
PSM_LANG_SUPPORTED="zh en ko ru"
LANG_DIR="${LANG_DIR:-$PSM_ROOT/lang}"

# 解析当前语言：PSM_LANG 环境变量 > state_get psm_lang > 默认；非受支持则回退默认。
_i18n_resolve_lang() {
    local l="${PSM_LANG:-}"
    [[ -z "$l" ]] && l="$(state_get psm_lang 2>/dev/null || true)"
    [[ -z "$l" ]] && l="$PSM_LANG_DEFAULT"
    [[ " $PSM_LANG_SUPPORTED " == *" $l "* ]] || l="$PSM_LANG_DEFAULT"
    printf '%s' "$l"
}

# 加载顺序：先装 zh 基底（保证缺键回退中文），再按所选语言覆盖。
# 每种语言都是「单文件 lang/<lang>.sh（框架级）+ 分模块目录 lang/<lang>/*.sh（各模块）」。
# 分模块目录让每个模块拥有独立语言文件，便于维护与并行迁移（互不冲突）。
i18n_init() {
    PSM_LANG="$(_i18n_resolve_lang)"
    MSG=()
    local _f
    # 中文基底
    [[ -f "$LANG_DIR/zh.sh" ]] && source "$LANG_DIR/zh.sh"
    for _f in "$LANG_DIR"/zh/*.sh;  do [[ -f "$_f" ]] && source "$_f"; done
    # 所选语言覆盖（缺键自动落到上面的中文基底）
    if [[ "$PSM_LANG" != "zh" ]]; then
        [[ -f "$LANG_DIR/${PSM_LANG}.sh" ]] && source "$LANG_DIR/${PSM_LANG}.sh"
        for _f in "$LANG_DIR/${PSM_LANG}"/*.sh; do [[ -f "$_f" ]] && source "$_f"; done
    fi
    # 显式返回 0：上面的 [[ ]] 在某些路径下判否会返回 1，调用方（manager.sh/install.sh
    # 等均 set -euo pipefail）source common.sh 时会因此中止。此处兜底避免误触 errexit。
    return 0
}

# t <key> [printf 参数...] → stdout 文案。
# 无参数：原样输出（不解释转义，多行安全）。有参数：按 printf 模板填充。
# 缺键：回显 ⟪key⟫ 便于一眼发现漏翻（不会静默空白）。
t() {
    local key="$1"; shift
    if [[ -z "${MSG[$key]+x}" ]]; then printf '⟪%s⟫' "$key"; return; fi
    local tmpl="${MSG[$key]}"
    if (( $# )); then printf "$tmpl" "$@"; else printf '%s' "$tmpl"; fi
}

# 运行时切换并持久化。
i18n_set_lang() {
    local l="$1"
    [[ " $PSM_LANG_SUPPORTED " == *" $l "* ]] || { log_error "$(t i18n.unsupported "$l")"; return 1; }
    state_set psm_lang "$l"
    PSM_LANG="$l"
    i18n_init
}

# 交互式语言选择器（菜单/安装共用）。
i18n_pick_lang() {
    echo -e "  1. 简体中文\n  2. English\n  3. 한국어\n  4. Русский"
    read -rp "$(echo -e "${CYAN}选择语言 / Select language / 언어 선택 / Выберите язык [1]: ${NC}")" _c
    case "${_c:-1}" in
        2) i18n_set_lang en ;;
        3) i18n_set_lang ko ;;
        4) i18n_set_lang ru ;;
        *) i18n_set_lang zh ;;
    esac
}
