#!/usr/bin/env bash
# cloudflare/tunnel.sh — Cloudflare Tunnel: expose a local service (Docker app,
# admin panel, anything on 127.0.0.1) to the internet without opening any
# inbound port — cloudflared makes an outbound-only connection to Cloudflare's
# edge. One tunnel per server is enough; each exposed hostname is just another
# ingress rule on that same tunnel.
#
# Reuses the API token already configured via cloudflare.sh's cf_setup_api()
# (state_get cf_api_token / _cf_curl) — does not touch cloudflare.sh. Only the
# Cloudflare Account ID (a Tunnel-specific credential the DNS/DDNS flows never
# needed) is stored here, in its own config file.

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../cloudflare.sh"

CFT_CFG_DIR="$CFG_DIR/cloudflare"
CFT_CFG="$CFT_CFG_DIR/tunnel.conf"
CFT_BIN="/usr/local/bin/cloudflared"

_cft_load_cfg() {
    CF_ACCOUNT_ID=""
    CFT_TUNNEL_ID=""
    CFT_TUNNEL_NAME=""
    # shellcheck source=/dev/null
    [[ -f "$CFT_CFG" ]] && source "$CFT_CFG"
}

_cft_save_cfg() {
    mkdir -p "$CFT_CFG_DIR"
    cat > "$CFT_CFG" <<EOF
CF_ACCOUNT_ID="${CF_ACCOUNT_ID}"
CFT_TUNNEL_ID="${CFT_TUNNEL_ID}"
CFT_TUNNEL_NAME="${CFT_TUNNEL_NAME}"
EOF
}

_cft_ensure_account_id() {
    _cft_load_cfg
    [[ -n "$CF_ACCOUNT_ID" ]] && return 0
    echo -e "${YELLOW}Tunnel 功能需要 Cloudflare Account ID（跟 DNS/DDNS 用的 API Token 不是一回事）${NC}"
    echo -e "${YELLOW}在 Cloudflare 控制台任意域名概览页右侧栏可以看到 Account ID${NC}"
    ask CF_ACCOUNT_ID "Cloudflare Account ID"
    [[ -z "$CF_ACCOUNT_ID" ]] && { log_error "Account ID 不能为空"; return 1; }
    _cft_save_cfg
}

_cft_install_binary() {
    command -v cloudflared &>/dev/null && return 0
    log_step "正在安装 cloudflared..."
    local arch; arch=$(get_arch)
    local cf_arch
    case "$arch" in
        amd64) cf_arch="amd64" ;;
        arm64) cf_arch="arm64" ;;
        arm32) cf_arch="arm" ;;
        *) log_error "cloudflared 不支持此架构：$arch"; return 1 ;;
    esac
    curl -fsSL -o "$CFT_BIN" \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}" \
        || { log_error "下载失败"; return 1; }
    chmod +x "$CFT_BIN"
    log_ok "cloudflared 已安装：$("$CFT_BIN" --version 2>/dev/null | head -1)"
}

# Creates the (single, per-server) tunnel on first use; no-ops if one already exists.
_cft_ensure_tunnel() {
    _cft_load_cfg
    [[ -n "$CFT_TUNNEL_ID" ]] && return 0

    local token; token=$(state_get "cf_api_token")
    [[ -z "$token" ]] && { log_error "请先在「Cloudflare 管理 → 设置 API 凭据」配置 API Token"; return 1; }

    _cft_ensure_account_id || return 1
    _cft_install_binary || return 1

    local name; ask name "隧道名称（仅用于在 Cloudflare 后台识别）" "psm-$(hostname -s 2>/dev/null || echo tunnel)"
    log_step "正在创建 Cloudflare Tunnel..."
    local resp
    resp=$(_cf_curl -X POST "$CF_API/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" \
        -d "{\"name\":\"${name}\",\"config_src\":\"cloudflare\"}")
    if [[ "$(echo "$resp" | jq -r '.success')" != "true" ]]; then
        log_error "创建隧道失败：$(echo "$resp" | jq -r '.errors[0].message // "未知错误"')"
        return 1
    fi

    CFT_TUNNEL_ID=$(echo "$resp" | jq -r '.result.id')
    CFT_TUNNEL_NAME="$name"
    local tunnel_token; tunnel_token=$(echo "$resp" | jq -r '.result.token')
    _cft_save_cfg

    log_step "正在安装 cloudflared 系统服务..."
    if "$CFT_BIN" service install "$tunnel_token"; then
        log_ok "隧道 ${name}（${CFT_TUNNEL_ID}）已创建并启动"
    else
        log_error "cloudflared 服务安装失败"
        return 1
    fi
}

# ── Ingress (hostname → local service) management ─────────────────────────────
_cft_get_ingress() {
    _cf_curl "$CF_API/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CFT_TUNNEL_ID}/configurations" \
        | jq -c '.result.config.ingress // []'
}

_cft_put_ingress() {
    _cf_curl -X PUT "$CF_API/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CFT_TUNNEL_ID}/configurations" \
        -d "{\"config\":{\"ingress\":${1}}}"
}

# Add (or replace) a hostname → local service rule, plus the matching DNS
# CNAME. Applies live — cloudflared picks up remotely-managed config changes
# over its existing connection, no restart needed.
# Usage: cft_add_ingress <hostname> <local_bind:local_port>
cft_add_ingress() {
    local hostname="$1" target="$2"
    _cft_ensure_tunnel || return 1
    _cft_load_cfg

    local current; current=$(_cft_get_ingress)
    # Drop any existing rule for this hostname and the trailing catch-all,
    # then re-append hostname rule + catch-all so it always stays last.
    local updated; updated=$(echo "$current" | jq -c \
        --arg h "$hostname" --arg svc "http://${target}" '
        [.[] | select((.hostname // "") != $h and (.service // "") != "http_status:404")]
        + [{"hostname":$h,"service":$svc}]
        + [{"service":"http_status:404"}]')

    local resp; resp=$(_cft_put_ingress "$updated")
    if [[ "$(echo "$resp" | jq -r '.success')" != "true" ]]; then
        log_error "写入 ingress 规则失败：$(echo "$resp" | jq -r '.errors[0].message // "未知错误"')"
        return 1
    fi

    local zone_id; zone_id=$(cf_get_zone_id "$hostname")
    if [[ -z "$zone_id" || "$zone_id" == "null" ]]; then
        log_error "未找到 ${hostname} 所在的 Zone——该域名必须已托管在这个 Cloudflare 账号下"
        return 1
    fi
    local dns_resp; dns_resp=$(_cf_curl -X POST "$CF_API/zones/${zone_id}/dns_records" \
        -d "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"${CFT_TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}")
    if [[ "$(echo "$dns_resp" | jq -r '.success')" != "true" ]]; then
        log_warn "DNS 记录：$(echo "$dns_resp" | jq -r '.errors[0].message // "创建失败"')（如果是"记录已存在"可忽略）"
    fi

    log_ok "已通过 Cloudflare Tunnel 暴露：https://${hostname} → ${target}"
    log_info "不需要在防火墙开放任何端口，几秒内生效"
}

cft_remove_ingress() {
    local hostname="$1"
    _cft_load_cfg
    [[ -z "$CFT_TUNNEL_ID" ]] && { log_warn "尚未创建 Tunnel"; return 0; }

    local current; current=$(_cft_get_ingress)
    local updated; updated=$(echo "$current" | jq -c --arg h "$hostname" \
        '[.[] | select((.hostname // "") != $h)]')
    _cft_put_ingress "$updated" >/dev/null

    local zone_id; zone_id=$(cf_get_zone_id "$hostname")
    if [[ -n "$zone_id" && "$zone_id" != "null" ]]; then
        local rec_id; rec_id=$(_cf_curl "$CF_API/zones/${zone_id}/dns_records?type=CNAME&name=${hostname}" \
            | jq -r '.result[0].id // empty')
        [[ -n "$rec_id" ]] && _cf_curl -X DELETE "$CF_API/zones/${zone_id}/dns_records/${rec_id}" >/dev/null
    fi
    log_ok "已移除 ${hostname} 的 Tunnel 暴露"
}

cft_list_ingress() {
    _cft_load_cfg
    [[ -z "$CFT_TUNNEL_ID" ]] && return 0
    echo -e "  ${BOLD}Ingress 规则：${NC}"
    local rules; rules=$(_cft_get_ingress | jq -r '.[] | select(.hostname) | "  \(.hostname)  →  \(.service)"')
    [[ -n "$rules" ]] && echo "$rules" || echo "    （无）"
}

# ── Status / menu ─────────────────────────────────────────────────────────────
cft_status() {
    _cft_load_cfg
    echo -e "\n${BOLD}${BLUE}══ Cloudflare Tunnel 状态 ══════════════════${NC}"
    if [[ -z "$CFT_TUNNEL_ID" ]]; then
        echo -e "  ${YELLOW}尚未创建 Tunnel${NC}"
    else
        echo -e "  隧道名称：${CFT_TUNNEL_NAME}"
        echo -e "  隧道 ID：${CFT_TUNNEL_ID}"
        if systemctl is-active --quiet cloudflared 2>/dev/null; then
            echo -e "  服务状态：${GREEN}运行中${NC}"
        else
            echo -e "  服务状态：${RED}未运行${NC}"
        fi
        cft_list_ingress
    fi
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"
}

cft_uninstall() {
    _cft_load_cfg
    ask_yn "确认卸载 cloudflared 并删除该 Tunnel？（对应的 DNS 记录不会自动清理，需要手动删除）" N || return 0
    systemctl stop cloudflared 2>/dev/null || true
    [[ -x "$CFT_BIN" ]] && "$CFT_BIN" service uninstall 2>/dev/null || true
    if [[ -n "$CFT_TUNNEL_ID" ]]; then
        _cf_curl -X DELETE "$CF_API/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CFT_TUNNEL_ID}" >/dev/null
    fi
    rm -f "$CFT_CFG"
    log_ok "Tunnel 已卸载"
}

cft_menu() {
    while true; do
        cft_status
        show_menu "Cloudflare Tunnel" \
            "创建 / 确保 Tunnel 已就绪" \
            "添加域名暴露（hostname → 本机服务）" \
            "移除域名暴露" \
            "卸载 Tunnel"

        case "$MENU_CHOICE" in
            1) _cft_ensure_tunnel; press_enter ;;
            2)
                local h t
                ask h "要暴露的域名（例如 app.example.com，需已托管在这个 Cloudflare 账号）"
                ask t "本机服务地址（例如 127.0.0.1:8080）"
                cft_add_ingress "$h" "$t"
                press_enter ;;
            3)
                local h; ask h "要移除的域名"
                cft_remove_ingress "$h"
                press_enter ;;
            4) cft_uninstall; press_enter ;;
            0) return ;;
        esac
    done
}
