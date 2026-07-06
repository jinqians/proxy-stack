#!/usr/bin/env bash
# docker/backup.sh — back up & restore Docker named volumes for PSM-managed
# Compose projects. Every app-store template (Portainer, Vaultwarden, etc.)
# stores its data in a named volume under Docker's own storage
# (/var/lib/docker/volumes/), not under /opt/psm/compose — so backup.sh's
# existing `cp -a /opt/psm/compose ...` step never touched it. Bind-mount
# data dirs (docker_add_project()'s ./<name>-data pattern) live inside
# /opt/psm/compose and are already covered by that existing step; this file
# only fills the named-volume gap.
#
# Wired into backup.sh's existing full/selective backup+restore flows as one
# more component, rather than a separate parallel backup system — so "完整
# 备份" actually means complete.

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../docker.sh"

# Named volumes referenced by any PSM-managed compose project's top-level
# `volumes:` block.
_dkb_list_named_volumes() {
    local f
    for f in "$DOCKER_COMPOSE_DIR"/*/docker-compose.yml; do
        [[ -f "$f" ]] || continue
        awk '/^volumes:/{found=1; next}
             found && /^[[:space:]]+[a-zA-Z0-9_.-]+:/{gsub(/^[[:space:]]+|:$/,""); print; next}
             found && /^[^[:space:]]/{found=0}' "$f"
    done | sort -u
}

# Usage: docker_backup_volumes <dest_dir>  (creates <dest_dir>/docker_volumes/*.tar.gz)
docker_backup_volumes() {
    local dest="$1"
    command -v docker &>/dev/null || return 0
    [[ -d "$DOCKER_COMPOSE_DIR" ]] || return 0

    local vol found=0
    while IFS= read -r vol; do
        [[ -z "$vol" ]] && continue
        docker volume inspect "$vol" &>/dev/null || continue
        if (( found == 0 )); then mkdir -p "$dest/docker_volumes"; found=1; fi
        log_step "$(t docker.backup.volume_backuping "$vol")"
        docker run --rm \
            -v "${vol}:/vol_data:ro" \
            -v "${dest}/docker_volumes:/backup" \
            alpine sh -c "tar -czf /backup/${vol}.tar.gz -C /vol_data ." \
            2>/dev/null || log_warn "$(t docker.backup.volume_backup_fail "$vol")"
    done < <(_dkb_list_named_volumes)
    (( found )) && log_ok "$(t docker.backup.done)" || log_info "$(t docker.backup.none_found)"
}

# Usage: docker_restore_volumes <src_dir>  (reads <src_dir>/docker_volumes/*.tar.gz)
docker_restore_volumes() {
    local src="$1"
    [[ -d "$src/docker_volumes" ]] || { log_info "$(t docker.restore.no_volumes)"; return 0; }
    command -v docker &>/dev/null || { log_warn "$(t docker.restore.no_docker)"; return 0; }

    local f vol restored=0
    for f in "$src/docker_volumes"/*.tar.gz; do
        [[ -f "$f" ]] || continue
        vol=$(basename "$f" .tar.gz)
        docker volume create "$vol" >/dev/null 2>&1
        log_step "$(t docker.restore.volume_restoring "$vol")"
        if docker run --rm \
            -v "${vol}:/vol_data" \
            -v "${src}/docker_volumes:/backup:ro" \
            alpine sh -c "rm -rf /vol_data/* /vol_data/.[!.]* 2>/dev/null; tar -xzf /backup/${vol}.tar.gz -C /vol_data" \
            2>/dev/null; then
            restored=$(( restored + 1 ))
        else
            log_warn "$(t docker.restore.volume_restore_fail "$vol")"
        fi
    done
    (( restored > 0 )) && log_ok "$(t docker.restore.done "$restored")"
}

docker_list_volume_backups() {
    local dest="$1"
    [[ -d "$dest/docker_volumes" ]] || { log_info "$(t docker.backup.no_volumes)"; return 0; }
    echo -e "\n${BOLD}$(t docker.backup.list_title)${NC}"
    local f
    for f in "$dest/docker_volumes"/*.tar.gz; do
        [[ -f "$f" ]] || continue
        printf "  %-30s %s\n" "$(basename "$f" .tar.gz)" "$(du -sh "$f" 2>/dev/null | cut -f1)"
    done
}
