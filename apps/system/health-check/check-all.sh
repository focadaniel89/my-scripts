#!/bin/bash

# ==============================================================================
# GLOBAL HEALTH CHECK
# Scans system for known applications and reports their installation/service status
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/docker.sh"

echo ""
log_info "═══════════════════════════════════════════"
log_info "  System Health & Installation Status"
log_info "═══════════════════════════════════════════"
echo ""

# Table Header
printf "%-25s | %-15s | %-15s | %-20s\n" "APPLICATION" "INSTALLED" "STATUS" "VERSION/NOTE"
printf "%s\n" "--------------------------------------------------------------------------------"

check_app_status() {
    local app_name="$1"
    local check_type="$2" # binary, docker, service
    local check_target="$3" # binary name, container name, service name
    
    local installed="NO"
    local status="-"
    local version="-"
    
    case "$check_type" in
        binary)
            if command -v "$check_target" &>/dev/null; then
                installed="YES"
                if pgrep -x "$check_target" &>/dev/null; then
                    status="${GREEN}Running${NC}"
                else
                    status="${RED}Stopped${NC}"
                fi
                version=$("$check_target" --version 2>/dev/null | head -n1 | awk '{print $NF}' | cut -d',' -f1)
            fi
            ;;
        service)
            if command -v "$check_target" &>/dev/null; then
                 installed="YES"
                 if systemctl is-active --quiet "$check_target" 2>/dev/null; then
                     status="${GREEN}Active${NC}"
                 else
                     status="${RED}Inactive${NC}"
                 fi
            fi
            # Special handling for Nginx/Redis where binary might differ from service name
            if [ "$check_target" = "nginx" ] && [ "$installed" = "NO" ] && command -v nginx &>/dev/null; then
                 installed="YES"
                 if systemctl is-active --quiet nginx 2>/dev/null; then status="${GREEN}Active${NC}"; else status="${RED}Inactive${NC}"; fi
            fi
             if [ "$check_target" = "redis-server" ] && [ "$installed" = "NO" ] && command -v redis-server &>/dev/null; then
                 installed="YES"
                 if systemctl is-active --quiet redis-server 2>/dev/null; then status="${GREEN}Active${NC}"; else status="${RED}Inactive${NC}"; fi
            fi
            ;;
        docker)
            if command -v docker &>/dev/null && run_sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${check_target}$"; then
                installed="YES"
                if run_sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${check_target}$"; then
                     status="${GREEN}Running${NC}"
                else
                     status="${RED}Stopped${NC}"
                fi
                # Try to get image tag as version proxy
                version=$(run_sudo docker inspect --format='{{.Config.Image}}' "$check_target" 2>/dev/null | cut -d':' -f2)
            fi
            ;;
    esac
    
    # Format Output
    if [ "$installed" = "YES" ]; then
         printf "%-25s | ${GREEN}%-15s${NC} | %-24b | %-20s\n" "$app_name" "$installed" "$status" "${version:0:20}"
    else
         printf "%-25s | ${RED}%-15s${NC} | %-15s | %-20s\n" "$app_name" "$installed" "$status" "$version"
    fi
}

# --- Infrastructure ---
check_app_status "Docker Engine" "binary" "docker"
check_app_status "Nginx Proxy" "service" "nginx"

# --- Databases ---
check_app_status "PostgreSQL" "docker" "postgres"
check_app_status "MongoDB" "docker" "mongodb"
check_app_status "Redis" "service" "redis-server"
check_app_status "MariaDB" "docker" "mariadb"

# --- System ---
check_app_status "Fail2Ban" "service" "fail2ban"
check_app_status "UFW Firewall" "service" "ufw"

# --- Apps ---
check_app_status "Portainer" "docker" "portainer"
check_app_status "N8N Automation" "docker" "n8n"
check_app_status "Uptime Kuma" "docker" "uptime-kuma"

echo ""
log_info "Done."
echo ""
