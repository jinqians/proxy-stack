#!/usr/bin/env bash
# ruleset/apply.sh — 把解析好的规则集落地到 mihomo / sing-box。
#
# 两边都走各自的原生通道，保真度最高、也不需要我们自己造轮子：
#
#   mihomo   rule-providers（type:http, behavior:classical, format:text）
#            URL 直接交给 mihomo，它自己按 interval 刷新，不重启、不断连。
#            连 IP-ASN 这种我们解析不了的类型也能吃到——原生通道的好处。
#
#   sing-box rule_set（type:local, format:source）。远程 rule_set 只认 sing-box
#            自己的 .srs/JSON，社区表是 Surge 文本，所以必须本地转换；好在
#            1.10 起「本地规则集文件改动会自动重载」，刷新同样不重启、不断连。
#
#   Xray     没有规则集概念，只能把规则内联展开进 routing rules。规则存在我们自己
#            的 parsed JSON 里，_route_build_xray_rule 按名字去取并展开，所以刷新
#            内容后必须重写配置并重启 Xray——三个核心里只有它要断一次连。

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

RS_TAG_PREFIX="psm-"
RS_SB_DIR="/etc/sing-box/rulesets"
RS_MH_RULE_DIR="/etc/mihomo/rules"
RS_MH_INTERVAL="${RS_MH_INTERVAL:-86400}"

RS_TIMER_SVC="/etc/systemd/system/psm-ruleset-update.service"
RS_TIMER="/etc/systemd/system/psm-ruleset-update.timer"

rs_tag() { printf '%s%s' "$RS_TAG_PREFIX" "$1"; }

rs_core_label() {
    case "$1" in
        singbox) echo "sing-box" ;;
        mihomo)  echo "mihomo" ;;
        xray)    echo "Xray" ;;
        *)       echo "$1" ;;
    esac
}

# ── sing-box ─────────────────────────────────────────────────────────────────
rs_sb_path() { printf '%s/%s.json' "$RS_SB_DIR" "$(rs_tag "$1")"; }

# 解析结果 → sing-box source 规则集文件。
# 关键：域名与 IP 必须拆成两条 headless rule。同一条规则里的不同字段是 AND
# 语义（域名匹配器 与 IP 匹配器 都要命中），写在一起等于永远不触发；而 domain /
# domain_suffix / domain_keyword 同属域名匹配器，放一起才是 OR，正是我们要的。
# version 用 1：这里只用到 v1 就有的字段，写低版本能让老内核也读得动。
# 纯函数：解析结果 → sing-box source JSON（只吐 stdout，便于快照测试）。
_rs_sb_source_json() {
    jq -c '{
        version: 1,
        rules: (
            ( if ((.domain|length) + (.domain_suffix|length) + (.domain_keyword|length)) > 0
              then [ { domain: .domain, domain_suffix: .domain_suffix,
                       domain_keyword: .domain_keyword }
                     | with_entries(select(.value | length > 0)) ]
              else [] end )
          + ( if (.ip_cidr|length) > 0 then [ { ip_cidr: .ip_cidr } ] else [] end )
        )
    }' <<<"$1"
}

rs_sb_write() {
    local name="$1" parsed
    parsed=$(rs_parsed_json "$name") || return 1
    mkdir -p "$RS_SB_DIR"
    _rs_sb_source_json "$parsed" > "$(rs_sb_path "$name")" || return 1
    chmod 600 "$(rs_sb_path "$name")" 2>/dev/null || true
}

rs_sb_bind() {
    local name="$1" target="$2"
    source "$LIB_DIR/singbox/routing.sh"
    _sb_require_installed || return 1
    rs_sb_write "$name" || { log_error "$(t rs.apply.write_fail "sing-box")"; return 1; }

    local rules id entry
    rules=$(_sb_route_load)
    # 同名规则集只保留一条绑定，改出口就是覆盖
    rules=$(echo "$rules" | jq --arg n "$name" \
        '[.[] | select((.rule_type != "ruleset") or (.value != $n))]')
    id=$(echo "$rules" | jq -r '[.[].id // "r0" | ltrimstr("r") | tonumber] | max // 0
                                | . + 1 | "r" + tostring')
    entry=$(jq -nc --arg id "$id" --arg n "$name" --arg t "$target" \
        --arg remark "$(t rs.bind.remark "$name")" \
        '{id:$id, remark:$remark, rule_type:"ruleset", value:$n, target:$t}')
    _sb_route_save "$(echo "$rules" | jq --argjson e "$entry" '. + [$e]')"

    if ! _sb_route_apply; then
        log_error "$(t rs.apply.fail "sing-box")"
        return 1
    fi
    log_ok "$(t rs.bind.done "$name" "sing-box" "$target")"
}

rs_sb_unbind() {
    local name="$1"
    source "$LIB_DIR/singbox/routing.sh"
    [[ -f "$SB_CFG" ]] || return 0
    _sb_route_save "$(_sb_route_load | jq --arg n "$name" \
        '[.[] | select((.rule_type != "ruleset") or (.value != $n))]')"
    _sb_route_apply || true
    rm -f "$(rs_sb_path "$name")"
}

rs_sb_target_of() {
    source "$LIB_DIR/singbox/routing.sh"
    _sb_route_load | jq -r --arg n "$1" \
        '[.[] | select(.rule_type == "ruleset" and .value == $n)][0].target // empty'
}

# ── mihomo ───────────────────────────────────────────────────────────────────
# provider 的 url 存在规则条目里，_mh_route_apply 据此重建 rule-providers，
# 这样 mihomo 模块不需要反过来依赖 ruleset 模块。
rs_mh_bind() {
    local name="$1" target="$2" url="$3"
    source "$LIB_DIR/mihomo/routing.sh"
    _mh_require_installed || return 1
    mkdir -p "$RS_MH_RULE_DIR"

    local st prev rules id
    st=$(_mh_route_load); prev="$st"
    rules=$(echo "$st" | jq --arg n "$name" \
        '[(.rules // [])[] | select((.kind != "ruleset") or (.value != $n))]')
    id=$(echo "$rules" | jq -r '[.[].id // "r0" | ltrimstr("r") | tonumber] | max // 0
                                | . + 1 | "r" + tostring')
    rules=$(echo "$rules" | jq --arg id "$id" --arg n "$name" --arg t "$target" --arg u "$url" \
        --arg remark "$(t rs.bind.remark "$name")" \
        '. + [{id:$id, remark:$remark, kind:"ruleset", value:$n, url:$u, target:$t}]')
    _mh_route_save "$(echo "$st" | jq --argjson r "$rules" '.rules = $r')"

    if ! _mh_route_apply; then
        _mh_route_save "$prev"
        log_error "$(t rs.apply.fail "mihomo")"
        return 1
    fi
    log_ok "$(t rs.bind.done "$name" "mihomo" "$target")"
}

rs_mh_unbind() {
    local name="$1"
    source "$LIB_DIR/mihomo/routing.sh"
    [[ -f "$MH_CFG" ]] || return 0
    local st; st=$(_mh_route_load)
    _mh_route_save "$(echo "$st" | jq --arg n "$name" \
        '.rules = [(.rules // [])[] | select((.kind != "ruleset") or (.value != $n))]')"
    _mh_route_apply || true
    rm -f "$RS_MH_RULE_DIR/$(rs_tag "$name").list"
}

rs_mh_target_of() {
    source "$LIB_DIR/mihomo/routing.sh"
    _mh_route_load | jq -r --arg n "$1" \
        '[(.rules // [])[] | select(.kind == "ruleset" and .value == $n)][0].target // empty'
}

# ── Xray ─────────────────────────────────────────────────────────────────────
# 规则内联展开在 _route_build_xray_rule 里做（它按名字读 parsed JSON），这里只
# 负责把绑定写进路由存储并触发一次重建 + 重启。
rs_xray_bind() {
    local name="$1" target="$2"
    source "$LIB_DIR/xray/routing.sh"
    _xray_require_installed || return 1
    [[ -s "$(rs_parsed_path "$name")" ]] || { log_error "$(t rs.apply.write_fail "Xray")"; return 1; }

    local rules id entry
    rules=$(_route_load | jq --arg n "$name" \
        '[.[] | select((.rule_type != "ruleset") or (.value != $n))]')
    id=$(echo "$rules" | jq -r '[.[].id // "r0" | ltrimstr("r") | tonumber] | max // 0
                                | . + 1 | "r" + tostring')
    entry=$(jq -nc --arg id "$id" --arg n "$name" --arg ot "$target" \
        --arg remark "$(t rs.bind.remark "$name")" \
        '{id:$id, remark:$remark, rule_type:"ruleset", value:$n, outbound_tag:$ot}')
    _route_save "$(echo "$rules" | jq --argjson e "$entry" '. + [$e]')"

    if ! _route_apply_to_xray || ! xray_test_restart; then
        log_error "$(t rs.apply.fail "Xray")"
        return 1
    fi
    log_ok "$(t rs.bind.done "$name" "Xray" "$target")"
    log_info "$(t rs.apply.xray_inline)"
}

rs_xray_unbind() {
    local name="$1"
    source "$LIB_DIR/xray/routing.sh"
    [[ -f "$XRAY_CFG" ]] || return 0
    _route_save "$(_route_load | jq --arg n "$name" \
        '[.[] | select((.rule_type != "ruleset") or (.value != $n))]')"
    _route_apply_to_xray || true
    xray_test_restart || true
}

rs_xray_target_of() {
    source "$LIB_DIR/xray/routing.sh"
    _route_load | jq -r --arg n "$1" \
        '[.[] | select(.rule_type == "ruleset" and .value == $n)][0].outbound_tag // empty'
}

# ── 统一入口 ─────────────────────────────────────────────────────────────────
rs_bind_core() {
    local core="$1" name="$2" target="$3" url="$4"
    case "$core" in
        singbox) rs_sb_bind "$name" "$target" ;;
        xray)    rs_xray_bind "$name" "$target" ;;
        mihomo)  rs_mh_bind "$name" "$target" "$url" ;;
        *) log_error "$(t rs.core.unsupported "$core")"; return 1 ;;
    esac
}

rs_unbind_core() {
    case "$1" in
        singbox) rs_sb_unbind "$2" ;;
        xray)    rs_xray_unbind "$2" ;;
        mihomo)  rs_mh_unbind "$2" ;;
        *) return 1 ;;
    esac
}

rs_target_of() {
    case "$1" in
        singbox) rs_sb_target_of "$2" ;;
        xray)    rs_xray_target_of "$2" ;;
        mihomo)  rs_mh_target_of "$2" ;;
        *) return 1 ;;
    esac
}

# 刷新已落库的规则集内容（不改绑定）。mihomo 端 provider 由内核自己按 interval
# 刷新，这里刷的是我们本地的解析副本与 sing-box 的规则集文件。
# sing-box 1.10+ 会自己发现文件变化并重载，所以不重启、不断连。
rs_refresh_one() {
    local name="$1" quiet="${2:-0}"
    local set_json url old_total new_total
    set_json=$(rs_set_get "$name") || return 1
    [[ -n "$set_json" ]] || return 1
    url=$(jq -r '.url' <<<"$set_json")
    old_total=$(jq -r '.total // 0' <<<"$set_json")

    rs_stage "$url" 1 || { rs_stage_cleanup; return 1; }
    new_total=$(jq -r '.total' "$RS_STAGE_PARSED")

    if ! rs_change_ok "$old_total" "$new_total"; then
        log_warn "$(t rs.update.suspicious "$name" "$old_total" "$new_total")"
        _rs_log "refresh $name refused: $old_total -> $new_total"
        rs_stage_cleanup
        return 2
    fi

    rs_commit "$name" "$url"
    rs_stage_cleanup
    # sing-box 侧只要文件在就刷新它；没绑定过就不会有这个文件，跳过即可。
    [[ -f "$(rs_sb_path "$name")" ]] && rs_sb_write "$name"
    (( quiet )) || log_ok "$(t rs.update.done "$name" "$old_total" "$new_total")"
    _rs_log "refresh $name: $old_total -> $new_total"
    return 0
}

rs_refresh_all() {
    local quiet="${1:-0}" name rc=0
    local names; names=$(rs_set_names)
    [[ -n "$names" ]] || { (( quiet )) || log_warn "$(t rs.list.empty)"; return 0; }
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        rs_refresh_one "$name" "$quiet" || rc=1
    done <<<"$names"
    return $rc
}

# ── 非交互刷新（manager.sh --ruleset-update，由每日 timer 调用）────────────────
# 三个核心的刷新代价完全不同，这里的分工是：
#   mihomo   什么都不用做——provider 由内核自己按 interval 拉，我们连碰都不用碰；
#   sing-box rs_refresh_one 已经重写了本地规则集文件，内核发现文件变化会自己重载；
#   Xray     规则是内联进 config.json 的，必须重建配置并重启，所以只在「内容真的
#            变了 且 确实有 Xray 绑定」时才动它——不为一次没有变化的拉取断用户的连接。
rs_update_cli() {
    _rs_init
    local names; names=$(rs_set_names)
    [[ -n "$names" ]] || return 0

    local name before after rc=0 xray_dirty=0
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        before=$(rs_set_get "$name" | jq -r '.total // 0')
        if rs_refresh_one "$name" 1; then
            after=$(rs_set_get "$name" | jq -r '.total // 0')
            if [[ "$before" != "$after" ]] && [[ -n "$(rs_xray_target_of "$name" 2>/dev/null || true)" ]]; then
                xray_dirty=1
            fi
        else
            rc=1
        fi
    done <<<"$names"

    if (( xray_dirty )); then
        source "$LIB_DIR/xray/routing.sh"
        if _route_apply_to_xray && xray_test_restart; then
            _rs_log "xray: rules rebuilt and service restarted"
        else
            _rs_log "xray: rebuild failed"
            rc=1
        fi
    fi
    return $rc
}

# ── 每日自动更新 ─────────────────────────────────────────────────────────────
rs_timer_active() { systemctl is-active --quiet psm-ruleset-update.timer 2>/dev/null; }

rs_timer_enable() {
    cat > "$RS_TIMER_SVC" <<EOF
[Unit]
Description=PSM rule-set update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${PSM_ROOT}/manager.sh --ruleset-update
StandardOutput=journal
StandardError=journal
EOF
    # RandomizedDelaySec：这些规则表都托管在同一个社区仓库，所有装了 PSM 的机器
    # 在同一秒去拉对人家不友好，随机推迟最多一小时错开。
    cat > "$RS_TIMER" <<'EOF'
[Unit]
Description=PSM rule-set update timer

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now psm-ruleset-update.timer &>/dev/null || true
    log_ok "$(t rs.timer.enabled)"
}

rs_timer_disable() {
    systemctl disable --now psm-ruleset-update.timer &>/dev/null || true
    rm -f "$RS_TIMER_SVC" "$RS_TIMER"
    systemctl daemon-reload 2>/dev/null || true
    log_ok "$(t rs.timer.disabled)"
}
