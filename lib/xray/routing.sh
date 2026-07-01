#!/usr/bin/env bash
# xray/routing.sh — Traffic routing rules management (split traffic to outbounds)
# Manages rules with outboundTag starting with "out-" (PSM outbound prefix).

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
source "$(dirname "${BASH_SOURCE[0]}")/outbound.sh"

ROUTE_CFG="$CFG_DIR/xray/routing_rules.json"

# ── State helpers ─────────────────────────────────────────────────────────────
_route_load() {
    [[ -f "$ROUTE_CFG" ]] && jq '.' "$ROUTE_CFG" 2>/dev/null || echo '[]'
}

_route_save() {
    mkdir -p "$(dirname "$ROUTE_CFG")"
    printf '%s' "$1" | jq '.' > "$ROUTE_CFG"
}

_route_count() { _route_load | jq 'length' 2>/dev/null; }

_route_next_id() {
    local max; max=$(_route_load | jq '[.[].id // "r0" | ltrimstr("r") | tonumber] | max // 0' 2>/dev/null)
    printf 'r%d' "$(( max + 1 ))"
}

# ── Build Xray routing rule JSON from stored entry ────────────────────────────
_route_build_xray_rule() {
    local e="$1"
    local rtype; rtype=$(echo "$e"  | jq -r '.rule_type')
    local val;   val=$(echo "$e"    | jq -r '.value')
    local outtag; outtag=$(echo "$e" | jq -r '.outbound_tag')

    case "$rtype" in
    geosite)
        # Xray-core has NO top-level "geosite" rule field — geosite entries must
        # go INTO the "domain" array, each prefixed with "geosite:". Emitting a
        # bare {"geosite":[...]} key is silently ignored, so the rule never fires.
        # value may be comma-separated ("netflix,openai"); prefix is idempotent
        # so a user-typed "geosite:netflix" isn't double-prefixed.
        local arr; arr=$(echo "$val" | tr ',' '\n' \
            | sed -E 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d;s/^(geosite:)?/geosite:/' \
            | jq -R . | jq -sc .)
        jq -n --argjson dm "$arr" --arg ot "$outtag" \
            '{"type":"field","domain":$dm,"outboundTag":$ot}'
        ;;
    geoip)
        # Same story for geoip: it belongs in the "ip" array as "geoip:us".
        local arr; arr=$(echo "$val" | tr ',' '\n' \
            | sed -E 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d;s/^(geoip:)?/geoip:/' \
            | jq -R . | jq -sc .)
        jq -n --argjson ip "$arr" --arg ot "$outtag" \
            '{"type":"field","ip":$ip,"outboundTag":$ot}'
        ;;
    domain)
        local arr; arr=$(echo "$val" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R . | jq -sc .)
        jq -n --argjson dm "$arr" --arg ot "$outtag" \
            '{"type":"field","domain":$dm,"outboundTag":$ot}'
        ;;
    ip)
        local arr; arr=$(echo "$val" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R . | jq -sc .)
        jq -n --argjson ip "$arr" --arg ot "$outtag" \
            '{"type":"field","ip":$ip,"outboundTag":$ot}'
        ;;
    inbound)
        local arr; arr=$(echo "$val" | tr ',' '\n' | jq -R . | jq -sc .)
        jq -n --argjson ib "$arr" --arg ot "$outtag" \
            '{"type":"field","inboundTag":$ib,"outboundTag":$ot}'
        ;;
    esac
}

# ── Sync routing state → Xray config ─────────────────────────────────────────
_route_apply_to_xray() {
    [[ -f "$XRAY_CFG" ]] || return 1
    local rules; rules=$(_route_load)
    local count; count=$(echo "$rules" | jq 'length')

    local tmp; tmp=$(mktemp)

    # Remove all PSM routing rules (outboundTag starts with "out-"),
    # preserving api/blocked/direct rules untouched.
    jq 'del(.routing.rules[] | select(
            (.outboundTag // "") | startswith("out-")
        ))' "$XRAY_CFG" > "$tmp"

    # Set domainStrategy if any geosite/domain rules exist
    local needs_dns=0
    echo "$rules" | jq -e '[.[].rule_type] | any(. == "geosite" or . == "domain")' &>/dev/null \
        && needs_dns=1
    if (( needs_dns )); then
        local tmp2; tmp2=$(mktemp)
        jq '.routing.domainStrategy = "IPIfNonMatch"' "$tmp" > "$tmp2"
        mv "$tmp2" "$tmp"
    fi

    # Build PSM rule array
    local psm_rules='[]'
    local i
    for (( i=0; i<count; i++ )); do
        local entry; entry=$(echo "$rules" | jq ".[$i]")
        local xrule; xrule=$(_route_build_xray_rule "$entry")
        [[ -n "$xrule" ]] && psm_rules=$(echo "$psm_rules" | jq ". += [$xrule]")
    done

    # Insert PSM rules right after the api rule (highest routing priority)
    local tmp2; tmp2=$(mktemp)
    jq --argjson pr "$psm_rules" '
        .routing.rules =
            [.routing.rules[]? | select(.outboundTag == "api")]
            + $pr
            + [.routing.rules[]? | select(.outboundTag != "api")]
    ' "$tmp" > "$tmp2"
    mv "$tmp2" "$XRAY_CFG"
    rm -f "$tmp"
}

# ── Interactive: add rule ─────────────────────────────────────────────────────
route_add_wizard() {
    _xray_require_installed || return

    # Must have at least one outbound
    local ob_count; ob_count=$(_outb_count)
    if (( ob_count == 0 )); then
        log_error "请先在「出站节点管理」中添加至少一个出站节点"
        return
    fi

    echo -e "\n${BOLD}添加路由规则${NC}"

    # Pick outbound
    echo ""
    echo "  可用出站节点："
    local ob_tags=() ob_i=0
    while IFS=$'\t' read -r tag proto addr remark; do
        ob_i=$((ob_i+1)); ob_tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} %-20s %-16s %s  %s\n" "$ob_i" "$tag" "$proto" "$addr" "$remark"
    done < <(_outb_list)
    echo ""
    local ob_sel
    read -rp "$(echo -e "${CYAN}选择出站节点（流量目标）: ${NC}")" ob_sel
    if ! [[ "$ob_sel" =~ ^[0-9]+$ ]] || (( ob_sel < 1 || ob_sel > ob_i )); then
        log_warn "无效选项"; return; fi
    local outbound_tag="${ob_tags[$((ob_sel-1))]}"

    # Pick rule type
    echo ""
    echo "  规则类型："
    echo "    1. GeoSite（按网站类别，如 netflix / openai / geolocation-!cn）"
    echo "    2. GeoIP  （按目标 IP 地区，如 us / jp / hk）"
    echo "    3. 域名   （精确/通配，逗号分隔，如 openai.com,chatgpt.com）"
    echo "    4. IP/CIDR（逗号分隔，如 1.2.3.0/24,5.6.7.8）"
    echo "    5. 入站标签（指定某个节点的流量，如 reality-abc）"
    echo ""
    local rt_sel
    read -rp "$(echo -e "${CYAN}选择规则类型 [1]: ${NC}")" rt_sel
    rt_sel="${rt_sel:-1}"

    local rule_type value remark
    case "$rt_sel" in
    1)
        rule_type="geosite"
        echo ""
        echo "  常用 GeoSite 分类（可逗号分隔多个）："
        echo "    netflix  openai  google  telegram  twitter  youtube"
        echo "    geolocation-!cn（所有非中国大陆域名）"
        ask value  "GeoSite 值" "netflix"
        ask remark "备注"       "${value} → ${outbound_tag}"
        ;;
    2)
        rule_type="geoip"
        echo ""
        echo "  常用 GeoIP 代码（可逗号分隔多个）："
        echo "    us  jp  hk  sg  gb  de  kr  tw  au"
        ask value  "GeoIP 代码" "us"
        ask remark "备注"       "GeoIP:${value} → ${outbound_tag}"
        ;;
    3)
        rule_type="domain"
        ask value  "域名列表（逗号分隔）" ""
        ask remark "备注" "${value} → ${outbound_tag}"
        [[ -z "$value" ]] && { log_error "域名不能为空"; return 1; }
        ;;
    4)
        rule_type="ip"
        ask value  "IP/CIDR 列表（逗号分隔）" ""
        ask remark "备注" "IP:${value} → ${outbound_tag}"
        [[ -z "$value" ]] && { log_error "IP 不能为空"; return 1; }
        ;;
    5)
        rule_type="inbound"
        echo ""
        echo "  提示：入站标签可在 Xray「列出入站配置」中查看"
        ask value  "入站标签（逗号分隔）" ""
        ask remark "备注" "inbound:${value} → ${outbound_tag}"
        [[ -z "$value" ]] && { log_error "入站标签不能为空"; return 1; }
        ;;
    *)
        log_warn "无效选项"; return ;;
    esac

    local id; id=$(_route_next_id)
    local entry
    entry=$(jq -n --arg id "$id" --arg remark "$remark" \
                   --arg rtype "$rule_type" --arg val "$value" --arg ot "$outbound_tag" \
        '{id:$id,remark:$remark,rule_type:$rtype,value:$val,outbound_tag:$ot}')

    local rules; rules=$(_route_load)
    rules=$(echo "$rules" | jq ". += [$entry]")
    _route_save "$rules"
    _route_apply_to_xray
    xray_test_restart   # config on disk is useless until Xray reloads it
    log_ok "路由规则已添加：${remark}"
}

# ── Interactive: delete rule ──────────────────────────────────────────────────
route_delete() {
    local count; count=$(_route_count)
    (( count == 0 )) && { log_warn "没有自定义路由规则"; return; }

    echo -e "\n${BOLD}删除路由规则${NC}"
    local rules; rules=$(_route_load)
    local ids_arr=() i=0
    while IFS= read -r entry; do
        i=$((i+1))
        local id remark rtype val ot
        id=$(echo "$entry"     | jq -r '.id')
        remark=$(echo "$entry" | jq -r '.remark // ""')
        rtype=$(echo "$entry"  | jq -r '.rule_type')
        val=$(echo "$entry"    | jq -r '.value')
        ot=$(echo "$entry"     | jq -r '.outbound_tag')
        ids_arr+=("$id")
        printf "  ${CYAN}%2d.${NC} [%-8s] %-30s → %-20s %s\n" \
            "$i" "$rtype" "$val" "$ot" "$remark"
    done < <(echo "$rules" | jq -c '.[]')

    local sel
    read -rp "$(echo -e "${CYAN}选择序号（0=取消）: ${NC}")" sel
    [[ -z "$sel" || "$sel" == "0" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "无效选项"; return; fi

    local del_id="${ids_arr[$((sel-1))]}"
    local new_rules; new_rules=$(echo "$rules" | jq "del(.[] | select(.id == \"$del_id\"))")
    _route_save "$new_rules"
    _route_apply_to_xray
    xray_test_restart
    log_ok "路由规则 ${del_id} 已删除"
}

# ── Display ───────────────────────────────────────────────────────────────────
route_show() {
    local count; count=$(_route_count)
    echo -e "\n${BOLD}${BLUE}══ 路由分流规则 ════════════════════════════════${NC}"
    if (( count == 0 )); then
        echo -e "  ${YELLOW}尚未配置路由规则${NC}"
        echo -e "  提示：先添加出站节点，再添加路由规则，Xray 将按规则把流量转发到对应出站。"
    else
        local rules; rules=$(_route_load)
        local i=0
        while IFS= read -r entry; do
            i=$((i+1))
            local rtype val ot remark
            rtype=$(echo "$entry"  | jq -r '.rule_type')
            val=$(echo "$entry"    | jq -r '.value')
            ot=$(echo "$entry"     | jq -r '.outbound_tag')
            remark=$(echo "$entry" | jq -r '.remark // ""')
            printf "  ${CYAN}%2d.${NC} [${YELLOW}%-8s${NC}] %-36s ${GREEN}→${NC} %-20s %s\n" \
                "$i" "$rtype" "$val" "$ot" "$remark"
        done < <(echo "$rules" | jq -c '.[]')
    fi
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════${NC}"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
route_menu() {
    _xray_require_installed || return
    while true; do
        show_menu "路由分流管理" \
            "查看路由规则" \
            "添加路由规则" \
            "删除路由规则" \
            "── 出站节点 ──" \
            "查看出站节点" \
            "添加出站节点" \
            "删除出站节点" \
            "── WARP 解锁 ──" \
            "WARP 解锁出站（Netflix / OpenAI 等）"

        case "$MENU_CHOICE" in
            1) route_show;      press_enter ;;
            2) route_add_wizard; press_enter ;;
            3) route_delete;    press_enter ;;
            4) ;;  # separator
            5) outb_show;       press_enter ;;
            6) outb_add_wizard; press_enter ;;
            7) outb_delete;     press_enter ;;
            8) ;;  # separator
            9)
                source "$(dirname "${BASH_SOURCE[0]}")/warp.sh"
                warp_menu
                ;;
            0) return ;;
        esac
    done
}
