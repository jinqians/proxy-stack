#!/usr/bin/env bash
# xray/reality_watchdog.sh — Multi-target camouflage failover for Reality nodes
#
# Reality's "dest" is the real TLS 1.3 site Xray forwards the handshake to for
# camouflage; "server_name" (SNI) must match a certificate actually served by
# that dest. If a camouflage target gets rate-limited/blocked/goes down, the
# node's handshake starts failing or looks suspicious. This module lets a
# Reality node have several candidate (SNI, dest) pairs, periodically health-
# checks the active one via a real TLS 1.3 handshake, and atomically switches
# to a healthy candidate (updating both the Xray inbound and, if the node is
# behind Nginx SNI routing, the Nginx SNI map) when it stays unhealthy.

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
source "$(dirname "${BASH_SOURCE[0]}")/reality.sh"

RWD_CFG="$CFG_DIR/xray/reality_watchdog.json"
RWD_LOG="${LOG_DIR}/reality_watchdog.log"
PSM_RWD_SVC="/etc/systemd/system/psm-reality-watchdog.service"
PSM_RWD_TIMER="/etc/systemd/system/psm-reality-watchdog.timer"
RWD_FAIL_THRESHOLD=2

# ── State helpers ─────────────────────────────────────────────────────────────
_rwd_init() {
    mkdir -p "$(dirname "$RWD_CFG")" "$LOG_DIR"
    [[ -f "$RWD_CFG" ]] || echo '{}' > "$RWD_CFG"
}

_rwd_load() { _rwd_init; cat "$RWD_CFG"; }
_rwd_save() { printf '%s' "$1" | jq '.' > "$RWD_CFG"; }

# Entry shape per reality tag:
# { "candidates": [{"server_name":"...", "dest":"host:port", "consec_fail":0}],
#   "active": "server_name_of_active_candidate",
#   "last_check": "...", "last_switch": "..." }
_rwd_get_entry() {
    _rwd_load | jq --arg t "$1" '.[$t] // empty'
}

_rwd_enabled_tags() { _rwd_load | jq -r 'keys[]' 2>/dev/null; }

# ── Health check: real TLS 1.3 handshake to the dest, SNI-matched ─────────────
_rwd_check_dest() {
    local dest="$1" sni="$2"
    local host="${dest%:*}" port="${dest##*:}"
    [[ -z "$host" || -z "$port" ]] && return 1
    timeout 6 openssl s_client -connect "${host}:${port}" -servername "$sni" \
        -tls1_3 -alpn h2,http/1.1 </dev/null 2>&1 | grep -q "BEGIN CERTIFICATE"
}

# ── Candidate management ───────────────────────────────────────────────────────
rwd_add_candidate() {
    local tag="$1" server_name="$2" dest="$3"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && { log_error "未找到 Reality 节点：$tag"; return 1; }

    _rwd_init
    local all; all=$(_rwd_load)
    local entry; entry=$(echo "$all" | jq --arg t "$tag" '.[$t] // {"candidates":[],"active":"","last_check":"","last_switch":""}')

    # Seed with the node's current (server_name, dest) as the active candidate
    # the first time a candidate pool is created for this tag.
    if [[ "$(echo "$entry" | jq -r '.candidates | length')" == "0" ]]; then
        local cur_sn cur_dest
        cur_sn=$(echo "$node" | jq -r '.server_name')
        cur_dest=$(echo "$node" | jq -r '.dest')
        entry=$(echo "$entry" | jq --arg sn "$cur_sn" --arg d "$cur_dest" \
            '.candidates += [{"server_name":$sn,"dest":$d,"consec_fail":0}] | .active = $sn')
    fi

    entry=$(echo "$entry" | jq --arg sn "$server_name" --arg d "$dest" \
        'if ([.candidates[].server_name] | index($sn)) then . else
            .candidates += [{"server_name":$sn,"dest":$d,"consec_fail":0}]
         end')

    all=$(echo "$all" | jq --arg t "$tag" --argjson e "$entry" '.[$t] = $e')
    _rwd_save "$all"
    log_ok "候选目标已添加：${server_name} → ${dest}（节点 ${tag}）"
}

rwd_remove_candidate() {
    local tag="$1" server_name="$2"
    local all; all=$(_rwd_load)
    local entry; entry=$(echo "$all" | jq --arg t "$tag" '.[$t] // empty')
    [[ -z "$entry" ]] && { log_warn "节点 ${tag} 尚未启用测活切换"; return 1; }

    local active; active=$(echo "$entry" | jq -r '.active')
    if [[ "$active" == "$server_name" ]]; then
        log_error "不能删除当前生效的候选目标（${server_name}），请先切换到其他候选"
        return 1
    fi
    entry=$(echo "$entry" | jq --arg sn "$server_name" '.candidates = [.candidates[] | select(.server_name != $sn)]')
    all=$(echo "$all" | jq --arg t "$tag" --argjson e "$entry" '.[$t] = $e')
    _rwd_save "$all"
    log_ok "候选目标已删除：${server_name}"
}

# ── Atomic switch: update reality.json + Nginx SNI map + apply to Xray ────────
_rwd_switch_node() {
    local tag="$1" new_sn="$2" new_dest="$3"
    local node; node=$(_reality_get_by_tag "$tag")
    [[ -z "$node" ]] && return 1

    local old_sn listen_addr port raw
    old_sn=$(echo "$node" | jq -r '.server_name')
    listen_addr=$(echo "$node" | jq -r '.listen_addr // "0.0.0.0"')
    port=$(echo "$node" | jq -r '.port')
    raw=$(echo "$node" | jq -r '.server_names_raw // .server_name')

    # REALITY only checks the incoming SNI against the serverNames whitelist —
    # auth for an already-connected client doesn't depend on dest matching
    # that SNI. So we accumulate rather than replace: every SNI ever handed
    # out in a client link stays valid forever, only the *new* SNI (used for
    # future links) and the camouflage dest move to the healthy candidate.
    local new_raw
    if echo ",${raw}," | grep -qF ",${new_sn},"; then
        new_raw="$raw"
    else
        new_raw="${raw},${new_sn}"
    fi

    node=$(echo "$node" | jq --arg sn "$new_sn" --arg raw "$new_raw" --arg d "$new_dest" \
        '.server_name = $sn | .server_names_raw = $raw | .dest = $d')
    _reality_upsert "$node"
    _reality_apply_all

    # Nginx-routed nodes: route the new SNI to the same backend too. The old
    # SNI's entry is left in place so previously distributed links keep working.
    if [[ "$listen_addr" == "127.0.0.1" ]]; then
        source "$LIB_DIR/nginx.sh" 2>/dev/null || true
        declare -f _sni_add_entry &>/dev/null && _sni_add_entry "$new_sn" "127.0.0.1:${port}" 2>/dev/null || true
    fi

    log_warn "[Reality 测活] 节点 ${tag}：伪装目标已切换 → ${new_sn}（${new_dest}），旧 SNI（${old_sn} 等）仍对已有客户端保持有效"
}

# ── Periodic check for one node ────────────────────────────────────────────────
rwd_check_node() {
    local tag="$1"
    local all; all=$(_rwd_load)
    local entry; entry=$(echo "$all" | jq --arg t "$tag" '.[$t] // empty')
    [[ -z "$entry" ]] && return 0

    # Node was deleted from reality.json since we last ran — drop its watchdog entry.
    if [[ -z "$(_reality_get_by_tag "$tag")" ]]; then
        all=$(echo "$all" | jq --arg t "$tag" 'del(.[$t])')
        _rwd_save "$all"
        return 0
    fi

    local now; now=$(date '+%Y-%m-%d %H:%M:%S')
    local count; count=$(echo "$entry" | jq '.candidates | length')
    (( count == 0 )) && return 0

    local i
    for (( i=0; i<count; i++ )); do
        local sn dest ok
        sn=$(echo "$entry"   | jq -r ".candidates[$i].server_name")
        dest=$(echo "$entry" | jq -r ".candidates[$i].dest")
        if _rwd_check_dest "$dest" "$sn"; then
            ok=1
            entry=$(echo "$entry" | jq ".candidates[$i].consec_fail = 0")
        else
            ok=0
            entry=$(echo "$entry" | jq ".candidates[$i].consec_fail += 1")
        fi
        echo "${now} tag=${tag} sni=${sn} dest=${dest} ok=${ok}" >> "$RWD_LOG"
    done
    entry=$(echo "$entry" | jq --arg now "$now" '.last_check = $now')

    # Decide whether the active candidate needs replacing
    local active fail
    active=$(echo "$entry" | jq -r '.active')
    fail=$(echo "$entry" | jq -r --arg sn "$active" '[.candidates[] | select(.server_name == $sn)][0].consec_fail // 0')

    if (( fail >= RWD_FAIL_THRESHOLD )); then
        local next; next=$(echo "$entry" | jq -r --arg sn "$active" \
            '[.candidates[] | select(.server_name != $sn and .consec_fail == 0)][0] // empty')
        if [[ -n "$next" ]]; then
            local next_sn next_dest
            next_sn=$(echo "$next"   | jq -r '.server_name')
            next_dest=$(echo "$next" | jq -r '.dest')
            _rwd_switch_node "$tag" "$next_sn" "$next_dest"
            entry=$(echo "$entry" | jq --arg sn "$next_sn" --arg now "$now" '.active = $sn | .last_switch = $now')
        else
            echo "${now} tag=${tag} WARN 当前目标连续失败 ${fail} 次，但没有健康的备选目标" >> "$RWD_LOG"
        fi
    fi

    all=$(echo "$all" | jq --arg t "$tag" --argjson e "$entry" '.[$t] = $e')
    _rwd_save "$all"
}

# ── Periodic check for all enabled nodes (systemd timer entry point) ──────────
rwd_check_all() {
    local tag
    while IFS= read -r tag; do
        [[ -n "$tag" ]] && rwd_check_node "$tag"
    done < <(_rwd_enabled_tags)
}

# ── Status display ─────────────────────────────────────────────────────────────
rwd_status() {
    echo -e "\n${BOLD}${BLUE}══ Reality 多目标测活切换状态 ══════════════════${NC}"
    local tags; tags=$(_rwd_enabled_tags)
    if [[ -z "$tags" ]]; then
        echo -e "  ${YELLOW}尚未为任何节点启用测活切换${NC}"
        echo -e "${BOLD}${BLUE}════════════════════════════════════════════════${NC}"
        return
    fi
    local tag
    while IFS= read -r tag; do
        local entry; entry=$(_rwd_get_entry "$tag")
        local active last_check; active=$(echo "$entry" | jq -r '.active'); last_check=$(echo "$entry" | jq -r '.last_check')
        echo -e "\n  ${CYAN}节点 ${tag}${NC}  最近检查：${last_check:-（未检查）}"
        echo "$entry" | jq -r '.candidates[] | "\(.server_name)\t\(.dest)\t\(.consec_fail)"' \
            | while IFS=$'\t' read -r sn dest fail; do
                local mark="  "
                [[ "$sn" == "$active" ]] && mark="${GREEN}●${NC} "
                local health="${GREEN}健康${NC}"
                (( fail > 0 )) && health="${RED}失败 ${fail} 次${NC}"
                printf "    %b%-28s %-28s %b\n" "$mark" "$sn" "$dest" "$(echo -e "$health")"
            done
    done <<< "$tags"
    echo -e "\n${BOLD}${BLUE}════════════════════════════════════════════════${NC}"
}

# ── Systemd timer ───────────────────────────────────────────────────────────────
_rwd_timer_active() { systemctl is-active --quiet psm-reality-watchdog.timer 2>/dev/null; }

_rwd_install_timer() {
    cat > "$PSM_RWD_SVC" <<EOF
[Unit]
Description=PSM Reality Camouflage-Target Watchdog
After=network.target

[Service]
Type=oneshot
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${PSM_ROOT}/manager.sh --reality-watchdog
StandardOutput=journal
StandardError=journal
EOF

    cat > "$PSM_RWD_TIMER" <<EOF
[Unit]
Description=PSM Reality Camouflage-Target Watchdog Timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now psm-reality-watchdog.timer
    log_ok "Reality 测活切换定时器已安装：每 10 分钟检测一次"
}

_rwd_uninstall_timer() {
    systemctl disable --now psm-reality-watchdog.timer 2>/dev/null || true
    rm -f "$PSM_RWD_SVC" "$PSM_RWD_TIMER"
    systemctl daemon-reload
    log_ok "Reality 测活切换定时器已删除"
}

# ── Interactive wizard ───────────────────────────────────────────────────────
_rwd_pick_reality_tag() {
    _show_node_list
    local tag; ask tag "节点标识"
    [[ -z "$(_reality_get_by_tag "$tag")" ]] && { log_error "未找到节点：$tag"; return 1; }
    printf '%s' "$tag"
}

rwd_setup_wizard() {
    local tag; tag=$(_rwd_pick_reality_tag) || return 1

    log_info "已为节点 ${tag} 启用测活切换（当前 SNI/伪装目标已作为候选 #1）"
    echo -e "  ${YELLOW}切换时只会更新伪装目标，已发给客户端的旧 SNI 链接会一直保留有效，${NC}"
    echo -e "  ${YELLOW}无需通知客户端更新——新客户端拿到的链接会使用当前生效的 SNI。${NC}"
    echo -e "  ${YELLOW}常见 TLS1.3 大站可作候选（需自行确认在目标地区可正常访问）：${NC}"
    echo "    www.microsoft.com:443   www.apple.com:443   www.amazon.com:443"
    echo "    addons.mozilla.org:443  www.samsung.com:443"
    echo ""

    while ask_yn "是否再添加一个候选伪装目标？" Y; do
        local sn dest
        ask sn   "伪装 SNI（如 www.apple.com）"
        ask dest "伪装目标 host:port（如 www.apple.com:443）" "${sn}:443"
        [[ -z "$sn" || -z "$dest" ]] && { log_error "SNI 和目标不能为空"; continue; }
        rwd_add_candidate "$tag" "$sn" "$dest"
    done

    ask_yn "是否现在启用定时自动测活切换？" Y && _rwd_install_timer
    log_ok "配置完成。可随时在此菜单查看状态或手动触发检测。"
}

rwd_disable_node() {
    local tag; tag=$(_rwd_pick_reality_tag) || return 1
    ask_yn "确认停用节点 ${tag} 的测活切换？（已切换过的 SNI/目标保持不变，仅停止监控）" N || return
    local all; all=$(_rwd_load)
    all=$(echo "$all" | jq --arg t "$tag" 'del(.[$t])')
    _rwd_save "$all"
    log_ok "已停用节点 ${tag} 的测活切换"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
rwd_menu() {
    while true; do
        rwd_status
        show_menu "Reality 多目标测活切换" \
            "为节点启用测活切换 / 添加候选目标" \
            "删除某节点的候选目标" \
            "立即执行一次检测" \
            "启用定时检测" \
            "停止定时检测" \
            "停用某节点的测活切换" \
            "查看检测日志"

        case "$MENU_CHOICE" in
            1) rwd_setup_wizard; press_enter ;;
            2)
                local tag; tag=$(_rwd_pick_reality_tag) && {
                    local sn; ask sn "要删除的候选 SNI"
                    rwd_remove_candidate "$tag" "$sn"
                }
                press_enter ;;
            3) log_step "正在检测（视候选数量需要数秒到数十秒）..."; rwd_check_all; log_ok "检测完成"; press_enter ;;
            4) _rwd_install_timer;   press_enter ;;
            5) _rwd_uninstall_timer; press_enter ;;
            6) rwd_disable_node;     press_enter ;;
            7) [[ -f "$RWD_LOG" ]] && tail -n 50 "$RWD_LOG" || log_warn "暂无日志"; press_enter ;;
            0) return ;;
        esac
    done
}
