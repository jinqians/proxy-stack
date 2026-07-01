#!/usr/bin/env bash
# docker.sh — Docker & Compose management, auto-bind 127.0.0.1

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DOCKER_COMPOSE_DIR="/opt/psm/compose"

# Warn (don't hard-block — re-deploying the same app on the same port is a
# legitimate case) if a candidate port collides with anything PSM already
# knows about (SSH, Xray/Hysteria2/Snell/SS-rust/ShadowTLS, honeypot ports)
# or is currently listening. Reuses the detection already built for the
# honeypot's own reserved-port guard rather than duplicating it.
# Returns 0 = proceed, 1 = abort.
_docker_check_port_conflict() {
    local port="$1"
    source "$LIB_DIR/security/honeypot.sh" 2>/dev/null || return 0
    declare -f _hp_is_reserved_port &>/dev/null || return 0
    _hp_is_reserved_port "$port" || return 0
    log_warn "端口 ${port} 似乎已被占用（本机服务、防火墙已放行的端口，或已配置的代理节点/蜜罐）"
    ask_yn "仍要使用这个端口吗？" N
}

# Ask how a container's port should bind. "仅本机" keeps it on 127.0.0.1 so
# the caller can layer Nginx/Tunnel on top afterwards; "直接暴露" binds
# 0.0.0.0 and opens the firewall port — no reverse proxy, no TLS, whatever
# the app itself provides is all the protection it gets, so this is opt-in
# and explicit rather than ever a default. Echoes the bind address to use.
_docker_pick_bind() {
    local port="$1"
    echo "" >&2
    echo "  这个服务的端口打算怎么绑？" >&2
    echo "    1. 仅本机监听（推荐；之后可以选择加 Nginx 反代或 Cloudflare Tunnel）" >&2
    echo "    2. 直接绑定公网 0.0.0.0（不经过反代，请自行确保该应用有基本的认证/访问控制）" >&2
    local choice; read -rp "$(echo -e "${CYAN}选择 [1]: ${NC}")" choice >&2
    if [[ "${choice:-1}" == "2" ]]; then
        source "$LIB_DIR/system.sh" 2>/dev/null || true
        declare -f firewall_open_port &>/dev/null && firewall_open_port "$port" "tcp" >&2
        echo "0.0.0.0"
    else
        echo "127.0.0.1"
    fi
}

# Offer to expose a locally-bound service publicly — either the existing
# Nginx reverse-proxy flow, or Cloudflare Tunnel (no inbound port opened at
# all; the domain just needs to be hosted in the same Cloudflare account).
# Only meaningful for a 127.0.0.1-bound service — skip this if _docker_pick_bind
# already went straight to 0.0.0.0.
# Usage: _docker_offer_expose <local target, e.g. 127.0.0.1:8080>
_docker_offer_expose() {
    local target="$1"
    echo ""
    echo "  是否需要把这个服务暴露到公网？"
    echo "    1. Nginx 反向代理（域名需解析到本机 IP，走 80/443）"
    echo "    2. Cloudflare Tunnel（不开放任何端口，域名需托管在 Cloudflare）"
    echo "    3. 不需要（仅本机访问）"
    local choice; read -rp "$(echo -e "${CYAN}选择 [3]: ${NC}")" choice
    case "${choice:-3}" in
        1)
            source "$LIB_DIR/nginx.sh"
            local domain; ask domain "反向代理域名"
            add_site <<< "$domain"$'\n'"$target"$'\n'"y"$'\n'"n"$'\n'"n" 2>/dev/null || {
                log_info "请在 Nginx → 添加 HTTP 站点 中指向 ${target}"
            }
            ;;
        2)
            source "$LIB_DIR/cloudflare/tunnel.sh" 2>/dev/null || { log_error "无法加载 Cloudflare Tunnel 模块"; return 1; }
            local domain; ask domain "要暴露的域名（例如 app.example.com，需已托管在 Cloudflare 账号下）"
            cft_add_ingress "$domain" "$target" || return 1
            if ask_yn "是否加一层 Cloudflare Access 门禁（需先过邮箱验证才能打开，Portainer/NPM 这类管理面板建议开）？" N; then
                source "$LIB_DIR/cloudflare/access.sh" 2>/dev/null \
                    && cfa_protect "$domain" \
                    || log_error "无法加载 Cloudflare Access 模块"
            fi
            ;;
        *)
            log_info "已跳过，仅本机可访问：${target}" ;;
    esac
}

# ── Install Docker ────────────────────────────────────────────────────────────
docker_install() {
    if is_installed docker; then
        log_info "Docker 已安装：$(docker --version)"
        return 0
    fi
    log_step "正在通过官方脚本安装 Docker..."
    curl -fsSL https://get.docker.com | sh
    svc_enable docker
    svc_start docker
    log_ok "Docker 已安装：$(docker --version)"
}

docker_install_compose() {
    if docker compose version &>/dev/null 2>&1; then
        log_info "Docker Compose 插件已可用。"
        return 0
    fi
    if is_installed docker-compose; then
        log_info "docker-compose 独立版：$(docker-compose --version)"
        return 0
    fi
    log_step "正在安装 Docker Compose 插件..."
    detect_os
    case "$OS_ID" in
        ubuntu|debian)
            pkg_install docker-compose-plugin 2>/dev/null \
                || pip3 install docker-compose 2>/dev/null
            ;;
        centos|rhel)
            yum install -y docker-compose-plugin 2>/dev/null \
                || pip3 install docker-compose 2>/dev/null
            ;;
    esac
    docker compose version &>/dev/null && log_ok "Compose 插件已安装。" \
        || log_error "安装可能失败，请手动检查。"
}

docker_uninstall() {
    ask_yn "是否删除 Docker？（所有容器和镜像将丢失）" N || return 0
    detect_os
    case "$OS_ID" in
        ubuntu|debian) apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin ;;
        centos|rhel)   yum remove -y docker-ce docker-ce-cli containerd.io ;;
    esac
    rm -rf /var/lib/docker /etc/docker
    log_ok "Docker 已删除。"
}

# ── Compose project management ────────────────────────────────────────────────
_compose_cmd() {
    if docker compose version &>/dev/null 2>&1; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

docker_add_project() {
    local name port
    ask name "项目名称（例如 uptime-kuma）"
    ask port "容器内部端口"

    local local_port; ask local_port "本机端口" "$(rand_port 3000 9000)"
    _docker_check_port_conflict "$local_port" || { log_info "已取消"; return 1; }
    local local_bind; local_bind=$(_docker_pick_bind "$local_port")
    local image; ask image "Docker 镜像（例如 louislam/uptime-kuma:1）"

    local project_dir="$DOCKER_COMPOSE_DIR/$name"
    mkdir -p "$project_dir"

    cat > "$project_dir/docker-compose.yml" <<EOF
version: "3.8"

services:
  ${name}:
    image: ${image}
    container_name: ${name}
    restart: unless-stopped
    ports:
      - "${local_bind}:${local_port}:${port}"
    volumes:
      - ./${name}-data:/app/data
    environment:
      - TZ=Asia/Shanghai
EOF

    log_info "Compose 文件已创建：$project_dir/docker-compose.yml"
    ask_yn "是否现在启动项目？" Y \
        && _compose_cmd -f "$project_dir/docker-compose.yml" up -d \
        && log_ok "$name 已在 ${local_bind}:${local_port} 运行" \
        || log_info "手动启动命令：docker compose -f $project_dir/docker-compose.yml up -d"

    [[ "$local_bind" == "127.0.0.1" ]] && _docker_offer_expose "${local_bind}:${local_port}"
}

docker_delete_project() {
    _list_projects
    local name; ask name "要删除的项目名称"
    local project_dir="$DOCKER_COMPOSE_DIR/$name"
    [[ -d "$project_dir" ]] || { log_error "未找到项目目录：$project_dir"; return 1; }
    ask_yn "是否停止并删除 $name？" N || return 0
    _compose_cmd -f "$project_dir/docker-compose.yml" down
    ask_yn "是否删除项目文件？" N && rm -rf "$project_dir"
    log_ok "项目 $name 已删除。"
}

_list_projects() {
    echo -e "\n${BOLD}Compose 项目：${NC}"
    ls "$DOCKER_COMPOSE_DIR" 2>/dev/null | while read -r proj; do
        local status="已停止"
        docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$proj" && status="运行中"
        printf "  %-25s %s\n" "$proj" "$status"
    done
}

docker_list_running() {
    docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null \
        || log_error "Docker 未运行"
}

docker_view_logs() {
    _list_projects
    local name; ask name "容器/项目名称"
    local lines; ask lines "日志行数" "100"
    docker logs --tail "$lines" -f "$name" 2>/dev/null \
        || _compose_cmd -f "$DOCKER_COMPOSE_DIR/$name/docker-compose.yml" logs --tail "$lines" -f
}

docker_prune() {
    ask_yn "是否删除已停止的容器、未使用的镜像和孤立卷？" N || return 0
    docker system prune -f
    docker volume prune -f 2>/dev/null || true
    log_ok "Docker 已清理。"
}

# ── Bind helper: ensure all compose services bind to 127.0.0.1 ───────────────
docker_audit_binds() {
    echo -e "\n${BOLD}检查 Compose 端口绑定（应为 127.0.0.1:*）：${NC}"
    find "$DOCKER_COMPOSE_DIR" -name "docker-compose.yml" | while read -r f; do
        local project; project=$(dirname "$f" | xargs basename)
        local bad_lines; bad_lines=$(grep -n "- \"[0-9]*:" "$f" 2>/dev/null)
        if [[ -n "$bad_lines" ]]; then
            echo -e "  ${RED}[警告]${NC} $project — 可能绑定到 0.0.0.0："
            echo "$bad_lines"
        else
            echo -e "  ${GREEN}[正常]${NC}  $project"
        fi
    done
}

# ── App store: read metadata from template comment headers ─────────────────────
_app_meta() {
    local file="$1" key="$2"
    grep "^# PSM-${key}:" "$file" 2>/dev/null | sed "s/^# PSM-${key}: //"
}

# Special handler for wg-easy (needs host + password prompt)
_handler_wg_easy() {
    local name="$1" label="$2" tpl="$3" default_port="$4"
    local dir="/opt/psm/compose/$name"

    if [[ -d "$dir" ]]; then
        log_warn "$label 已存在部署目录"
        ask_yn "是否停止并重新部署？" N || return 0
        _compose_cmd -f "$dir/docker-compose.yml" down 2>/dev/null || true
    fi

    local host; ask host "服务器公网 IP 或域名（客户端连接用）" "$(get_ipv4 2>/dev/null || echo '')"
    local port; ask port "管理面板本机端口" "$default_port"
    _docker_check_port_conflict "$port" || { log_info "已取消"; return 1; }
    # WireGuard 监听端口在模板里是写死的 51820/udp，不随管理面板端口变化，同样要查一遍
    _docker_check_port_conflict "51820" || { log_info "已取消"; return 1; }
    local bind; bind=$(_docker_pick_bind "$port")
    local password; ask password "管理面板登录密码"

    log_step "正在生成密码哈希..."
    local pw_hash yaml_hash
    pw_hash=$(docker run --rm ghcr.io/wg-easy/wg-easy wgpw "$password" 2>/dev/null \
        | grep -oE '\$2[aby]\$[0-9]+\$[A-Za-z0-9./]+' | head -1 || true)
    [[ -z "$pw_hash" ]] && { log_error "密码哈希生成失败，请确认 Docker 正常运行。"; return 1; }

    # Escape $ → $$ so docker-compose does not expand them as variables
    yaml_hash=$(printf '%s' "$pw_hash" | sed 's/\$/\$\$/g')

    mkdir -p "$dir"
    sed -e "s/__PORT__/$port/g" \
        -e "s/__HOST__/$host/g" \
        -e "s/__BIND__/$bind/g" \
        -e "s|__HASH__|$yaml_hash|g" \
        "$tpl" > "$dir/docker-compose.yml"

    log_step "正在启动 $label，请稍候..."
    if _compose_cmd -f "$dir/docker-compose.yml" up -d; then
        log_ok "$label 已启动"
        echo -e "  管理面板：${CYAN}http://${bind}:${port}${NC}"
        echo -e "  WireGuard：${CYAN}${host}:51820 / UDP${NC}（已直接对外监听，Tunnel 不适用于 UDP，无需额外配置）"
        [[ "$bind" == "127.0.0.1" ]] && _docker_offer_expose "127.0.0.1:${port}"
    else
        log_error "启动失败，请检查：docker logs $name"
    fi
}

# Generic deploy: read template, substitute __PORT__, run compose
_deploy_from_template() {
    local tpl="$1"
    local name;    name=$(_app_meta "$tpl" "NAME")
    local label;   label=$(_app_meta "$tpl" "LABEL")
    local def_port; def_port=$(_app_meta "$tpl" "PORT")
    local warn;    warn=$(_app_meta "$tpl" "WARN")
    local handler; handler=$(_app_meta "$tpl" "HANDLER")

    # Show warning + confirmation if defined
    if [[ -n "$warn" ]]; then
        echo -e "\n${YELLOW}注意：${warn}${NC}\n"
        ask_yn "确认继续？" N || return 0
    fi

    # Delegate to special handler if defined
    if [[ -n "$handler" ]]; then
        "_handler_${handler}" "$name" "$label" "$tpl" "$def_port"
        return
    fi

    local dir="/opt/psm/compose/$name"
    if [[ -d "$dir" ]]; then
        log_warn "$label 已存在部署目录：$dir"
        ask_yn "是否停止并重新部署？" N || return 0
        _compose_cmd -f "$dir/docker-compose.yml" down 2>/dev/null || true
    fi

    local port; ask port "$label 本机访问端口" "$def_port"
    _docker_check_port_conflict "$port" || { log_info "已取消"; return 1; }
    local bind; bind=$(_docker_pick_bind "$port")
    mkdir -p "$dir"
    sed -e "s/__PORT__/$port/g" -e "s/__BIND__/$bind/g" "$tpl" > "$dir/docker-compose.yml"

    log_step "正在拉取镜像并启动 $label，请稍候..."
    if _compose_cmd -f "$dir/docker-compose.yml" up -d; then
        log_ok "$label 已启动"
        echo -e "  本机地址：${CYAN}http://${bind}:${port}${NC}"
        [[ "$bind" == "127.0.0.1" ]] && _docker_offer_expose "127.0.0.1:${port}"
    else
        log_error "启动失败，请检查：docker logs $name"
    fi
}

# ── App store menu (dynamic — reads templates/docker/apps/) ────────────────────
docker_app_store() {
    local app_dir="$PSM_ROOT/templates/docker/apps"
    [[ -d "$app_dir" ]] || { log_error "应用模板目录不存在：$app_dir"; return 1; }

    # Load template files in sorted order
    local tpls=()
    while IFS= read -r f; do
        tpls+=("$f")
    done < <(find "$app_dir" -maxdepth 1 -name "*.yml" | sort)

    [[ ${#tpls[@]} -eq 0 ]] && { log_warn "未找到任何应用模板。"; return 1; }

    # Build label list for show_menu
    local labels=()
    for tpl in "${tpls[@]}"; do
        labels+=("$(_app_meta "$tpl" "LABEL")")
    done

    while true; do
        show_menu "一键部署应用" "${labels[@]}"
        [[ "$MENU_CHOICE" == "0" ]] && return
        local idx=$(( MENU_CHOICE - 1 ))
        if [[ $idx -ge 0 && $idx -lt ${#tpls[@]} ]]; then
            _deploy_from_template "${tpls[$idx]}"
            press_enter
        fi
    done
}



# ── Dependency check ─────────────────────────────────────────────────────────
_docker_check_deps() {
    ensure_pkg_deps curl
    if ! is_installed docker; then
        log_warn "Docker 未安装。"
        ask_yn "是否现在安装 Docker？" Y && docker_install || log_warn "大多数操作需要 Docker。"
    fi
}

# ── Menu ──────────────────────────────────────────────────────────────────────
docker_menu() {
    _docker_check_deps
    while true; do
        show_menu "Docker 管理" \
            "安装 Docker" \
            "安装 Docker Compose" \
            "卸载 Docker" \
            "一键部署应用" \
            "添加 Compose 项目" \
            "删除 Compose 项目" \
            "列出项目" \
            "列出运行中的容器" \
            "查看容器日志" \
            "审查端口绑定" \
            "清理未使用资源"

        case "$MENU_CHOICE" in
            1)  docker_install ;;
            2)  docker_install_compose ;;
            3)  docker_uninstall ;;
            4)  docker_app_store ;;
            5)  docker_add_project ;;
            6)  docker_delete_project ;;
            7)  _list_projects ;;
            8)  docker_list_running ;;
            9)  docker_view_logs ;;
            10) docker_audit_binds ;;
            11) docker_prune ;;
            0)  return ;;
        esac
        press_enter
    done
}
