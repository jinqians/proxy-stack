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
    log_warn "$(t docker.port_conflict "$port")"
    ask_yn "$(t docker.ask_use_port)" N
}

# Ask how a container's port should bind. "仅本机" keeps it on 127.0.0.1 so
# the caller can layer Nginx/Tunnel on top afterwards; "直接暴露" binds
# 0.0.0.0 and opens the firewall port — no reverse proxy, no TLS, whatever
# the app itself provides is all the protection it gets, so this is opt-in
# and explicit rather than ever a default. Echoes the bind address to use.
_docker_pick_bind() {
    local port="$1"
    echo "" >&2
    echo "  $(t docker.bind.title)" >&2
    echo "    $(t docker.bind.local)" >&2
    echo "    $(t docker.bind.public)" >&2
    local choice; read -rp "$(echo -e "${CYAN}$(t docker.ask_select_1)${NC}")" choice >&2
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
    echo "  $(t docker.expose.title)"
    echo "    $(t docker.expose.nginx)"
    echo "    $(t docker.expose.tunnel)"
    echo "    $(t docker.expose.none)"
    local choice; read -rp "$(echo -e "${CYAN}$(t docker.ask_select_3)${NC}")" choice
    case "${choice:-3}" in
        1)
            source "$LIB_DIR/nginx.sh"
            local domain; ask domain "$(t docker.ask.proxy_domain)"
            add_site <<< "$domain"$'\n'"$target"$'\n'"y"$'\n'"n"$'\n'"n" 2>/dev/null || {
                log_info "$(t docker.nginx_hint "$target")"
            }
            ;;
        2)
            source "$LIB_DIR/cloudflare/tunnel.sh" 2>/dev/null || { log_error "$(t docker.cft_load_fail)"; return 1; }
            local domain; ask domain "$(t docker.ask.expose_domain)"
            cft_add_ingress "$domain" "$target" || return 1
            if ask_yn "$(t docker.ask.cloudflare_access)" N; then
                source "$LIB_DIR/cloudflare/access.sh" 2>/dev/null \
                    && cfa_protect "$domain" \
                    || log_error "$(t docker.cfa_load_fail)"
            fi
            ;;
        *)
            log_info "$(t docker.expose_skipped "$target")" ;;
    esac
}

# ── Install Docker ────────────────────────────────────────────────────────────
# get.docker.com does NOT support Amazon Linux ("Unsupported distribution
# 'amzn'") or Oracle Linux ('ol'), and its Rocky/Alma handling has been flaky —
# so only the Debian family goes through the official script. The RHEL family
# uses Docker's own centos repo (the documented path for CentOS/Rocky/Alma/RHEL
# and the community-standard one for Oracle), and Amazon Linux installs the
# `docker` package Amazon maintains in its base repos.
docker_install() {
    if is_installed docker; then
        log_info "$(t docker.installed "$(docker --version)")"
        return 0
    fi
    detect_os
    case "$OS_ID" in
        amzn)
            log_step "$(t docker.install.amzn)"
            pkg_install docker || { log_error "$(t docker.install.failed)"; return 1; }
            ;;
        centos|rhel|rocky|almalinux|ol|fedora)
            log_step "$(t docker.install.repo)"
            local repo_os="centos"
            [[ "$OS_ID" == "fedora" ]] && repo_os="fedora"
            [[ "$OS_ID" == "rhel"   ]] && repo_os="rhel"
            local pkg_cmd repo_url
            pkg_cmd=$(_rhel_pkg_cmd)
            repo_url="https://download.docker.com/linux/${repo_os}/docker-ce.repo"
            if ! [[ -f /etc/yum.repos.d/docker-ce.repo ]]; then
                if ! "$pkg_cmd" config-manager --add-repo "$repo_url" 2>/dev/null; then
                    "$pkg_cmd" install -y dnf-plugins-core 2>/dev/null || true
                    "$pkg_cmd" config-manager --add-repo "$repo_url" 2>/dev/null \
                        || curl -fsSL "$repo_url" -o /etc/yum.repos.d/docker-ce.repo \
                        || { log_error "$(t docker.install.repo_fail)"; return 1; }
                fi
            fi
            "$pkg_cmd" install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin \
                || { log_error "$(t docker.install.failed)"; return 1; }
            ;;
        *)
            log_step "$(t docker.install.script)"
            curl -fsSL https://get.docker.com | sh || { log_error "$(t docker.install.failed)"; return 1; }
            ;;
    esac
    svc_enable docker
    svc_start docker || { log_error "$(t docker.service_start_fail)"; return 1; }
    log_ok "$(t docker.installed "$(docker --version)")"
}

docker_install_compose() {
    if docker compose version &>/dev/null 2>&1; then
        log_info "$(t docker.compose.plugin_ready)"
        return 0
    fi
    if is_installed docker-compose; then
        log_info "$(t docker.compose.standalone "$(docker-compose --version)")"
        return 0
    fi
    log_step "$(t docker.compose.installing)"
    # Family-wide package attempt first (works wherever the docker-ce repo or
    # the distro provides it) …
    pkg_install docker-compose-plugin 2>/dev/null || true

    # … then a universal fallback: the official compose binary as a CLI plugin.
    # This covers Amazon Linux (no docker-compose-plugin package) and any other
    # distro/repo combination that lacks the package. Arch-aware.
    if ! docker compose version &>/dev/null; then
        local arch plugin_dir
        case "$(uname -m)" in
            x86_64)  arch="x86_64"  ;;
            aarch64) arch="aarch64" ;;
            armv7l)  arch="armv7"   ;;
            *)       arch="" ;;
        esac
        if [[ -n "$arch" ]]; then
            plugin_dir="/usr/local/lib/docker/cli-plugins"
            mkdir -p "$plugin_dir"
            log_step "$(t docker.compose.downloading "$arch")"
            curl -fsSL \
                "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}" \
                -o "$plugin_dir/docker-compose" 2>/dev/null \
                && chmod +x "$plugin_dir/docker-compose"
        fi
    fi

    docker compose version &>/dev/null && log_ok "$(t docker.compose.installed)" \
        || log_error "$(t docker.compose.install_maybe_failed)"
}

docker_uninstall() {
    ask_yn "$(t docker.ask_uninstall)" N || return 0
    detect_os
    case "$OS_ID" in
        ubuntu|debian|raspbian)
            apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || true ;;
        amzn)
            "$(_rhel_pkg_cmd)" remove -y docker 2>/dev/null || true ;;
        centos|rhel|rocky|almalinux|ol|fedora)
            "$(_rhel_pkg_cmd)" remove -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || true ;;
    esac
    rm -rf /var/lib/docker /etc/docker
    rm -f /usr/local/lib/docker/cli-plugins/docker-compose
    log_ok "$(t docker.uninstalled)"
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
    ask name "$(t docker.ask.project_name)"
    ask port "$(t docker.ask.container_port)"

    local local_port; ask local_port "$(t docker.ask.local_port)" "$(rand_port 3000 9000)"
    _docker_check_port_conflict "$local_port" || { log_info "$(t common.cancelled)"; return 1; }
    local local_bind; local_bind=$(_docker_pick_bind "$local_port")
    local image; ask image "$(t docker.ask.image)"

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

    log_info "$(t docker.compose.created "$project_dir/docker-compose.yml")"
    ask_yn "$(t docker.ask.start_now)" Y \
        && _compose_cmd -f "$project_dir/docker-compose.yml" up -d \
        && log_ok "$(t docker.project.running "$name" "$local_bind" "$local_port")" \
        || log_info "$(t docker.manual_start "$project_dir/docker-compose.yml")"

    [[ "$local_bind" == "127.0.0.1" ]] && _docker_offer_expose "${local_bind}:${local_port}"
}

docker_delete_project() {
    _list_projects
    local name; ask name "$(t docker.ask.delete_project_name)"
    local project_dir="$DOCKER_COMPOSE_DIR/$name"
    [[ -d "$project_dir" ]] || { log_error "$(t docker.project_dir_missing "$project_dir")"; return 1; }
    ask_yn "$(t docker.ask.stop_delete "$name")" N || return 0
    _compose_cmd -f "$project_dir/docker-compose.yml" down
    ask_yn "$(t docker.ask.delete_files)" N && rm -rf "$project_dir"
    log_ok "$(t docker.project_deleted "$name")"
}

_list_projects() {
    echo -e "\n${BOLD}$(t docker.projects_title)${NC}"
    ls "$DOCKER_COMPOSE_DIR" 2>/dev/null | while read -r proj; do
        local status; status="$(t docker.status.stopped)"
        docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$proj" && status="$(t docker.status.running)"
        printf "  %-25s %s\n" "$proj" "$status"
    done
}

docker_list_running() {
    docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null \
        || log_error "$(t docker.not_running)"
}

docker_view_logs() {
    _list_projects
    local name; ask name "$(t docker.ask.container_name)"
    local lines; ask lines "$(t docker.ask.log_lines)" "100"
    docker logs --tail "$lines" -f "$name" 2>/dev/null \
        || _compose_cmd -f "$DOCKER_COMPOSE_DIR/$name/docker-compose.yml" logs --tail "$lines" -f
}

docker_prune() {
    ask_yn "$(t docker.ask_prune)" N || return 0
    docker system prune -f
    docker volume prune -f 2>/dev/null || true
    log_ok "$(t docker.pruned)"
}

# ── Bind helper: ensure all compose services bind to 127.0.0.1 ───────────────
docker_audit_binds() {
    echo -e "\n${BOLD}$(t docker.audit_title)${NC}"
    find "$DOCKER_COMPOSE_DIR" -name "docker-compose.yml" | while read -r f; do
        local project; project=$(dirname "$f" | xargs basename)
        local bad_lines; bad_lines=$(grep -n "- \"[0-9]*:" "$f" 2>/dev/null)
        if [[ -n "$bad_lines" ]]; then
            echo -e "  ${RED}$(t docker.audit.warn)${NC} $(t docker.audit.bad "$project")"
            echo "$bad_lines"
        else
            echo -e "  ${GREEN}$(t docker.audit.ok)${NC}  $project"
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
        log_warn "$(t docker.deploy.exists "$label")"
        ask_yn "$(t docker.ask.redeploy)" N || return 0
        _compose_cmd -f "$dir/docker-compose.yml" down 2>/dev/null || true
    fi

    local host; ask host "$(t docker.ask.wg_host)" "$(get_ipv4 2>/dev/null || echo '')"
    local port; ask port "$(t docker.ask.panel_port)" "$default_port"
    _docker_check_port_conflict "$port" || { log_info "$(t common.cancelled)"; return 1; }
    # WireGuard 监听端口在模板里是写死的 51820/udp，不随管理面板端口变化，同样要查一遍
    _docker_check_port_conflict "51820" || { log_info "$(t common.cancelled)"; return 1; }
    local bind; bind=$(_docker_pick_bind "$port")
    local password; ask password "$(t docker.ask.panel_password)"

    log_step "$(t docker.hashing_password)"
    local pw_hash yaml_hash
    pw_hash=$(docker run --rm ghcr.io/wg-easy/wg-easy wgpw "$password" 2>/dev/null \
        | grep -oE '\$2[aby]\$[0-9]+\$[A-Za-z0-9./]+' | head -1 || true)
    [[ -z "$pw_hash" ]] && { log_error "$(t docker.hash_fail)"; return 1; }

    # Escape $ → $$ so docker-compose does not expand them as variables
    yaml_hash=$(printf '%s' "$pw_hash" | sed 's/\$/\$\$/g')

    mkdir -p "$dir"
    sed -e "s/__PORT__/$port/g" \
        -e "s/__HOST__/$host/g" \
        -e "s/__BIND__/$bind/g" \
        -e "s|__HASH__|$yaml_hash|g" \
        "$tpl" > "$dir/docker-compose.yml"

    log_step "$(t docker.starting "$label")"
    if _compose_cmd -f "$dir/docker-compose.yml" up -d; then
        log_ok "$(t docker.started "$label")"
        echo -e "  $(t docker.panel_url) ${CYAN}http://${bind}:${port}${NC}"
        echo -e "  $(t docker.wireguard_endpoint) ${CYAN}${host}:51820 / UDP${NC} ($(t docker.wireguard_note))"
        [[ "$bind" == "127.0.0.1" ]] && _docker_offer_expose "127.0.0.1:${port}"
    else
        log_error "$(t docker.start_fail "$name")"
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
        echo -e "\n${YELLOW}$(t docker.warn_prefix "$warn")${NC}\n"
        ask_yn "$(t docker.ask_continue)" N || return 0
    fi

    # Delegate to special handler if defined
    if [[ -n "$handler" ]]; then
        "_handler_${handler}" "$name" "$label" "$tpl" "$def_port"
        return
    fi

    local dir="/opt/psm/compose/$name"
    if [[ -d "$dir" ]]; then
        log_warn "$(t docker.deploy.exists_dir "$label" "$dir")"
        ask_yn "$(t docker.ask.redeploy)" N || return 0
        _compose_cmd -f "$dir/docker-compose.yml" down 2>/dev/null || true
    fi

    local port; ask port "$(t docker.ask.app_port "$label")" "$def_port"
    _docker_check_port_conflict "$port" || { log_info "$(t common.cancelled)"; return 1; }
    local bind; bind=$(_docker_pick_bind "$port")
    mkdir -p "$dir"
    sed -e "s/__PORT__/$port/g" -e "s/__BIND__/$bind/g" "$tpl" > "$dir/docker-compose.yml"

    log_step "$(t docker.pulling_starting "$label")"
    if _compose_cmd -f "$dir/docker-compose.yml" up -d; then
        log_ok "$(t docker.started "$label")"
        echo -e "  $(t docker.local_url) ${CYAN}http://${bind}:${port}${NC}"
        [[ "$bind" == "127.0.0.1" ]] && _docker_offer_expose "127.0.0.1:${port}"
    else
        log_error "$(t docker.start_fail "$name")"
    fi
}

# ── App store menu (dynamic — reads templates/docker/apps/) ────────────────────
docker_app_store() {
    local app_dir="$PSM_ROOT/templates/docker/apps"
    [[ -d "$app_dir" ]] || { log_error "$(t docker.app_dir_missing "$app_dir")"; return 1; }

    # Load template files in sorted order
    local tpls=()
    while IFS= read -r f; do
        tpls+=("$f")
    done < <(find "$app_dir" -maxdepth 1 -name "*.yml" | sort)

    [[ ${#tpls[@]} -eq 0 ]] && { log_warn "$(t docker.app.none)"; return 1; }

    # Build label list for show_menu
    local labels=()
    for tpl in "${tpls[@]}"; do
        labels+=("$(_app_meta "$tpl" "LABEL")")
    done

    while true; do
        show_menu "$(t docker.app.menu)" "${labels[@]}"
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
        log_warn "$(t docker.not_installed)"
        ask_yn "$(t docker.ask_install_now)" Y && docker_install || log_warn "$(t docker.most_need_docker)"
    fi
}

# ── Menu ──────────────────────────────────────────────────────────────────────
docker_menu() {
    _docker_check_deps
    while true; do
        show_menu "$(t docker.menu.title)" \
            "$(t docker.menu.install)" \
            "$(t docker.menu.compose)" \
            "$(t docker.menu.uninstall)" \
            "$(t docker.menu.apps)" \
            "$(t docker.menu.add_project)" \
            "$(t docker.menu.delete_project)" \
            "$(t docker.menu.list_projects)" \
            "$(t docker.menu.list_running)" \
            "$(t docker.menu.logs)" \
            "$(t docker.menu.audit)" \
            "$(t docker.menu.prune)"

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
