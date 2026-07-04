#!/usr/bin/env bash
# realm.sh — realm TCP/UDP 中转（端口转发 / 流量中转）管理
#
# 典型用法：在网络优质的中转机（如 HK/SG）上监听一个端口，把流量转发到
# 落地机的代理端口。realm 只做 L4 转发，不解析/不解密流量，落地机上的
# 协议（Reality/SS/Hysteria2 等）配置无需改动。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

REALM_BIN="/usr/local/bin/realm"
REALM_CFG_DIR="/etc/realm"
REALM_TOML="${REALM_CFG_DIR}/config.toml"
REALM_SERVICE="/etc/systemd/system/realm.service"
REALM_STORE="$CFG_DIR/realm/rules.json"
REALM_RELEASES="https://github.com/zhboner/realm/releases"
REALM_FALLBACK_TAG="v2.9.4"

# ── Rule store（JSON 为唯一事实源，config.toml 由它生成）─────────────────────
_realm_load() {
    if [[ ! -f "$REALM_STORE" ]]; then
        mkdir -p "$(dirname "$REALM_STORE")"
        echo "[]" > "$REALM_STORE"
    fi
    cat "$REALM_STORE"
}
_realm_save() { mkdir -p "$(dirname "$REALM_STORE")"; printf '%s\n' "$1" > "$REALM_STORE"; }
_realm_count() { _realm_load | jq 'length' 2>/dev/null; }
_realm_get_by_tag() { _realm_load | jq --arg t "$1" '.[] | select(.tag == $t)' 2>/dev/null; }
_realm_list() {
    _realm_load | jq -r '.[] |
        "\(.tag)\t\(.listen_port)\t\(.remote_host)\t\(.remote_port)\t\(if .udp then "TCP+UDP" else "TCP" end)"' 2>/dev/null
}
_realm_upsert() {
    local n="$1" tag; tag=$(echo "$n" | jq -r '.tag')
    local rules; rules=$(_realm_load)
    rules=$(echo "$rules" | jq --arg t "$tag" --argjson n "$n" 'del(.[] | select(.tag == $t)) | . += [$n]')
    _realm_save "$rules"
}
_realm_delete() {
    local rules; rules=$(_realm_load)
    _realm_save "$(echo "$rules" | jq --arg t "$1" 'del(.[] | select(.tag == $t))')"
}

# remote 目标写进 TOML 时的地址：IPv6 需加方括号，IPv4/域名原样。
_realm_fmt_remote() {
    local host="$1" port="$2"
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        printf '[%s]:%s' "$host" "$port"
    else
        printf '%s:%s' "$host" "$port"
    fi
}

# ── 由 JSON 存储生成 realm 的 TOML 配置 ───────────────────────────────────────
_realm_gen_toml() {
    local rules; rules=$(_realm_load)
    local count; count=$(echo "$rules" | jq 'length')
    mkdir -p "$REALM_CFG_DIR"

    {
        echo "# 由 PSM 自动生成，请勿手动编辑；改动会在下次操作时被覆盖。"
        echo "# 增删改中转规则请使用 PSM「中转管理」菜单。"
        echo ""
        echo "[network]"
        echo "no_tcp = false"
        echo "use_udp = false"
        local i
        for ((i = 0; i < count; i++)); do
            local rule listen remote_host remote_port udp remote
            rule=$(echo "$rules" | jq ".[$i]")
            listen=$(echo "$rule"      | jq -r '.listen_port')
            remote_host=$(echo "$rule" | jq -r '.remote_host')
            remote_port=$(echo "$rule" | jq -r '.remote_port')
            udp=$(echo "$rule"         | jq -r '.udp')
            remote=$(_realm_fmt_remote "$remote_host" "$remote_port")
            echo ""
            echo "[[endpoints]]"
            echo "listen = \"0.0.0.0:${listen}\""
            echo "remote = \"${remote}\""
            if [[ "$udp" == "true" ]]; then
                echo "[endpoints.network]"
                echo "use_udp = true"
            fi
        done
    } > "$REALM_TOML"
    chmod 600 "$REALM_TOML" 2>/dev/null || true
}

# 重新生成配置并重启服务；若无规则则停止服务（realm 空 endpoints 会启动失败）。
_realm_apply() {
    _realm_gen_toml
    local count; count=$(_realm_count)
    if [[ "$count" == "0" ]]; then
        svc_stop realm 2>/dev/null || true
        log_info "已无中转规则，realm 服务已停止。"
        return 0
    fi
    svc_enable realm 2>/dev/null || true
    if svc_restart realm; then
        sleep 1
        if svc_is_active realm; then
            log_ok "realm 中转服务已生效（共 ${count} 条规则）。"
        else
            log_error "realm 启动后未处于运行状态，请用「查看日志」排查。"
            journalctl -u realm -n 15 --no-pager 2>/dev/null || true
            return 1
        fi
    else
        log_error "realm 服务重启失败，请用「查看日志」排查。"
        return 1
    fi
}

# ── 安装 ──────────────────────────────────────────────────────────────────────
realm_install() {
    ensure_pkg_deps curl tar jq
    require_cmd curl tar jq

    if [[ -f "$REALM_BIN" ]]; then
        log_info "realm 已安装：$("$REALM_BIN" --version 2>/dev/null | head -1)"
        ask_yn "是否重新安装 realm 二进制文件？" N || return 0
    fi

    local arch; arch=$(get_arch)
    local realm_arch
    case "$arch" in
        amd64) realm_arch="x86_64-unknown-linux-musl" ;;
        arm64) realm_arch="aarch64-unknown-linux-musl" ;;
        arm32) realm_arch="armv7-unknown-linux-musleabihf" ;;
        *)     die "realm 不支持此架构：$arch" ;;
    esac

    local tag
    log_step "正在获取 realm 最新版本..."
    tag=$(curl -fsSL "https://api.github.com/repos/zhboner/realm/releases/latest" 2>/dev/null \
          | jq -r '.tag_name // empty' || true)
    [[ "$tag" =~ ^v[0-9] ]] || { log_warn "无法获取最新版本，使用备用版本 ${REALM_FALLBACK_TAG}"; tag="$REALM_FALLBACK_TAG"; }

    local file="realm-${realm_arch}.tar.gz"
    local url="${REALM_RELEASES}/download/${tag}/${file}"
    local tmp_dir; tmp_dir=$(mktemp -d)

    log_step "正在下载 realm ${tag}（${realm_arch}）..."
    if ! curl -fsSL -o "$tmp_dir/$file" "$url"; then
        rm -rf "$tmp_dir"; die "下载失败：$url"
    fi
    tar -xzf "$tmp_dir/$file" -C "$tmp_dir" || { rm -rf "$tmp_dir"; die "解压失败：$file"; }
    if [[ ! -f "$tmp_dir/realm" ]]; then
        rm -rf "$tmp_dir"; die "压缩包中未找到 realm 可执行文件。"
    fi
    install -m 755 "$tmp_dir/realm" "$REALM_BIN"
    rm -rf "$tmp_dir"

    mkdir -p "$REALM_CFG_DIR"
    _realm_write_service
    systemctl daemon-reload
    log_ok "realm ${tag} 已安装。"

    # 保留已有规则；仅在存储为空时提示新增第一条。
    local count; count=$(_realm_count)
    if [[ "$count" == "0" ]]; then
        echo ""
        ask_yn "是否现在添加一条中转规则？" Y && realm_add_rule
    else
        _realm_apply
    fi
}

_realm_write_service() {
    cat > "$REALM_SERVICE" <<EOF
[Unit]
Description=realm relay service
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
ExecStart=${REALM_BIN} -c ${REALM_TOML}

[Install]
WantedBy=multi-user.target
EOF
}

# ── 端口 / 主机校验 ───────────────────────────────────────────────────────────
_realm_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

# ── 添加中转规则 ──────────────────────────────────────────────────────────────
realm_add_rule() {
    log_step "正在添加中转规则..."
    echo -e "  ${YELLOW}中转机监听「本机端口」，把流量转发到「落地机地址:端口」。"
    echo -e "  例如：客户端连本机 5000 → 转发到落地机 1.2.3.4:443（Reality 端口）。${NC}\n"

    local count; count=$(_realm_count)
    local tag listen_port remote_host remote_port
    ask tag "规则标识" "relay-$((count + 1))"
    local exist; exist=$(_realm_get_by_tag "$tag")
    [[ -n "$exist" ]] && { log_error "标识 '$tag' 已存在，请换一个。"; return 1; }

    ask listen_port "本机监听端口" "$(rand_port 20000 60000)"
    _realm_valid_port "$listen_port" || { log_error "无效端口"; return 1; }
    # 与已有规则的监听端口冲突会导致 realm 整体起不来，提前拦截。
    if _realm_load | jq -e --argjson p "$listen_port" 'any(.[]; .listen_port == $p)' >/dev/null 2>&1; then
        log_error "本机端口 ${listen_port} 已被其它中转规则占用。"; return 1
    fi
    _realm_port_conflict_warn "$listen_port"

    ask remote_host "落地机地址（IP 或域名）"
    [[ -z "$remote_host" ]] && { log_error "落地机地址不能为空。"; return 1; }
    ask remote_port "落地机端口" "443"
    _realm_valid_port "$remote_port" || { log_error "无效端口"; return 1; }

    local udp=false
    ask_yn "是否同时转发 UDP？（如落地为 Hysteria2/QUIC 需要）" N && udp=true

    local rule
    rule=$(jq -n \
        --arg tag "$tag" \
        --argjson lp "$listen_port" \
        --arg rh "$remote_host" \
        --argjson rp "$remote_port" \
        --argjson udp "$udp" \
        '{tag:$tag, listen_port:$lp, remote_host:$rh, remote_port:$rp, udp:$udp}')
    _realm_upsert "$rule"
    _realm_apply || return 1

    echo ""
    log_ok "中转规则 '$tag'：本机 ${listen_port} → ${remote_host}:${remote_port}"

    local proto; [[ "$udp" == "true" ]] && proto="both" || proto="tcp"
    ask_yn "是否现在放行防火墙端口 ${listen_port}/${proto}？" Y && {
        source "$LIB_DIR/system.sh"
        firewall_open_port "$listen_port" "$proto"
    }
}

# 监听端口若与本机已知服务/其它节点冲突则给出提示（不强制阻止）。
_realm_port_probe_warn() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -ltnu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${port}$" \
            && log_warn "端口 ${port} 当前已被本机某服务监听，可能与中转规则冲突。"
    fi
}

# 复用蜜罐/其它协议已登记的端口检测（若可用），并做一次实时监听探测。
_realm_port_conflict_warn() {
    local port="$1"
    if source "$LIB_DIR/security/honeypot.sh" 2>/dev/null \
       && declare -f _hp_is_reserved_port &>/dev/null \
       && _hp_is_reserved_port "$port"; then
        log_warn "端口 ${port} 似乎已被本机服务、防火墙已放行端口或已配置的节点/蜜罐占用。"
    fi
    _realm_port_probe_warn "$port"
}

# ── 删除中转规则 ──────────────────────────────────────────────────────────────
realm_delete_rule() {
    _realm_show_rules
    local count; count=$(_realm_count)
    (( count == 0 )) && return 0
    local tag; ask tag "要删除的规则标识"
    local rule; rule=$(_realm_get_by_tag "$tag")
    [[ -z "$rule" ]] && { log_error "未找到规则：$tag"; return 1; }
    local lp; lp=$(echo "$rule" | jq -r '.listen_port')
    ask_yn "确认删除规则 '$tag'（本机端口 ${lp}）？" N || return 0
    _realm_delete "$tag"
    _realm_apply
    log_info "规则 '$tag' 已删除。原监听端口 ${lp} 若已放行防火墙，不再使用时请手动关闭。"
}

# ── 修改中转规则 ──────────────────────────────────────────────────────────────
realm_modify_rule() {
    _realm_show_rules
    local count; count=$(_realm_count)
    (( count == 0 )) && return 0
    local tag; ask tag "要修改的规则标识"
    local rule; rule=$(_realm_get_by_tag "$tag")
    [[ -z "$rule" ]] && { log_error "未找到规则：$tag"; return 1; }

    local old_lp old_rh old_rp old_udp
    old_lp=$(echo "$rule"  | jq -r '.listen_port')
    old_rh=$(echo "$rule"  | jq -r '.remote_host')
    old_rp=$(echo "$rule"  | jq -r '.remote_port')
    old_udp=$(echo "$rule" | jq -r '.udp')

    local listen_port remote_host remote_port
    ask listen_port "本机监听端口" "$old_lp"
    _realm_valid_port "$listen_port" || { log_error "无效端口"; return 1; }
    if [[ "$listen_port" != "$old_lp" ]] \
       && _realm_load | jq -e --arg t "$tag" --argjson p "$listen_port" \
            'any(.[]; .tag != $t and .listen_port == $p)' >/dev/null 2>&1; then
        log_error "本机端口 ${listen_port} 已被其它中转规则占用。"; return 1
    fi
    ask remote_host "落地机地址（IP 或域名）" "$old_rh"
    [[ -z "$remote_host" ]] && { log_error "落地机地址不能为空。"; return 1; }
    ask remote_port "落地机端口" "$old_rp"
    _realm_valid_port "$remote_port" || { log_error "无效端口"; return 1; }

    local udp="$old_udp"
    if [[ "$old_udp" == "true" ]]; then
        ask_yn "是否继续转发 UDP？" Y && udp=true || udp=false
    else
        ask_yn "是否同时转发 UDP？" N && udp=true || udp=false
    fi

    rule=$(echo "$rule" | jq \
        --argjson lp "$listen_port" --arg rh "$remote_host" \
        --argjson rp "$remote_port" --argjson udp "$udp" \
        '.listen_port=$lp | .remote_host=$rh | .remote_port=$rp | .udp=$udp')
    _realm_upsert "$rule"
    _realm_apply || return 1
    log_ok "规则 '$tag' 已更新：本机 ${listen_port} → ${remote_host}:${remote_port}"

    if [[ "$listen_port" != "$old_lp" ]]; then
        local proto; [[ "$udp" == "true" ]] && proto="both" || proto="tcp"
        ask_yn "监听端口已变更，是否放行新端口 ${listen_port}/${proto}？" Y && {
            source "$LIB_DIR/system.sh"
            firewall_open_port "$listen_port" "$proto"
        }
        log_info "原端口 ${old_lp} 若已放行防火墙，不再使用时请手动关闭。"
    fi
}

# ── 显示规则列表 ──────────────────────────────────────────────────────────────
_realm_show_rules() {
    local lst; lst=$(_realm_list)
    if [[ -z "$lst" ]]; then
        log_warn "尚未配置任何中转规则。"
        return 1
    fi
    local ip; ip=$(get_ipv4 2>/dev/null || echo "?")
    echo -e "\n${BOLD}中转规则（本机 ${ip}）：${NC}"
    printf "  %-16s %-10s %-28s %s\n" "标识" "本机端口" "落地目标" "协议"
    echo "$lst" | while IFS=$'\t' read -r tag lp rh rp proto; do
        printf "  %-16s %-10s %-28s %s\n" "$tag" "$lp" "${rh}:${rp}" "$proto"
    done
}

# ── 供 manager.sh 节点总览调用 ────────────────────────────────────────────────
_realm_show_node_list() {
    echo -e "\n${BOLD}中转（realm）：${NC}"
    local count; count=$(_realm_count 2>/dev/null || echo 0)
    if [[ "$count" == "0" || -z "$count" ]]; then
        echo "  未配置"
        return
    fi
    local ip; ip=$(get_ipv4 2>/dev/null || echo "?")
    _realm_list | while IFS=$'\t' read -r tag lp rh rp proto; do
        printf "  %s %s:%s → %s:%s | %s\n" "$proto" "$ip" "$lp" "$rh" "$rp"
    done
}

# ── 卸载 ──────────────────────────────────────────────────────────────────────
realm_uninstall() {
    ask_yn "是否卸载 realm（程序 + 服务 + 所有中转规则）？" N || return 0
    svc_stop realm 2>/dev/null || true
    systemctl disable realm --quiet 2>/dev/null || true
    rm -f "$REALM_BIN" "$REALM_SERVICE"
    rm -rf "$REALM_CFG_DIR"
    rm -f "$REALM_STORE"
    systemctl daemon-reload
    log_ok "realm 及所有中转规则已删除。"
}

realm_logs() { journalctl -u realm -f --no-pager; }

# ── 依赖检查 ──────────────────────────────────────────────────────────────────
_realm_check_deps() {
    ensure_pkg_deps curl tar jq
    [[ -f "$REALM_BIN" ]] && return 0
    log_warn "realm 未安装。"
    ask_yn "是否现在安装 realm？" Y \
        && realm_install \
        || { log_error "此菜单需要 realm。"; return 1; }
}

# ── 菜单 ──────────────────────────────────────────────────────────────────────
realm_menu() {
    _realm_check_deps || return
    while true; do
        show_menu "中转管理（realm）" \
            "安装 / 重新安装" \
            "添加中转规则" \
            "修改中转规则" \
            "删除中转规则" \
            "列出中转规则" \
            "服务状态" \
            "重启服务" \
            "查看日志" \
            "卸载"

        case "$MENU_CHOICE" in
            1) realm_install ;;
            2) realm_add_rule ;;
            3) realm_modify_rule ;;
            4) realm_delete_rule ;;
            5) _realm_show_rules ;;
            6) svc_status realm ;;
            7) svc_restart realm && log_ok "realm 已重启。" ;;
            8) realm_logs ;;
            9) realm_uninstall ;;
            0) return ;;
        esac
        press_enter
    done
}
