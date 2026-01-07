#!/bin/bash

# ==============================================================================
# PRE-FLIGHT CHECKS LIBRARY
# Validates system resources before application installation
# ==============================================================================

set -euo pipefail

# Source required libraries
PREFLIGHT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${PREFLIGHT_LIB_DIR}/utils.sh" ]; then
    source "${PREFLIGHT_LIB_DIR}/utils.sh"
fi
if [ -f "${PREFLIGHT_LIB_DIR}/os-detect.sh" ]; then
    source "${PREFLIGHT_LIB_DIR}/os-detect.sh"
fi

# Check if enough disk space is available
# Args: $1 = required_gb
check_disk_space() {
    local required_gb=$1
    local required_kb=$((required_gb * 1024 * 1024))
    
    # Get available disk space in KB
    local available_kb=$(df / | tail -1 | awk '{print $4}')
    
    if [ "$available_kb" -lt "$required_kb" ]; then
        return 1
    fi
    
    return 0
}

# Check if enough RAM is available
# Args: $1 = required_gb
check_ram_available() {
    local required_gb=$1
    local required_mb=$((required_gb * 1024))
    
    # Get available RAM in MB
    local available_mb=$(free -m | awk '/^Mem:/{print $7}')
    
    if [ "$available_mb" -lt "$required_mb" ]; then
        return 1
    fi
    
    return 0
}

# Check if port is already in use
# Args: $1 = port_number
check_port_available() {
    local port=$1
    
    if command -v ss &> /dev/null; then
        if ss -tuln | grep -q ":${port} "; then
             return 1
        fi
    elif command -v netstat &> /dev/null; then
        if netstat -tuln | grep -q ":${port} "; then
            return 1
        fi
    elif command -v lsof &> /dev/null; then
         if lsof -i :$port >/dev/null; then
             return 1
         fi
    else
        # Try to install net-tools if missing and we are root/can sudo
        log_debug "Port check tools missing. Attempting to install net-tools..."
        install_package "net-tools" >/dev/null 2>&1 || true
        
        if command -v netstat &> /dev/null; then
             if netstat -tuln | grep -q ":${port} "; then
                return 1
             fi
        else
             log_warn "Cannot reliably check if port $port is in use (missing ss/netstat/lsof)"
             return 0
        fi
    fi

    
    return 0
}

# Get human-readable disk space
get_disk_space_human() {
    df -h / | tail -1 | awk '{print $4}'
}

# Get human-readable RAM
get_ram_available_human() {
    free -h | awk '/^Mem:/{print $7}'
}

# Main pre-flight check function
# Args: $1 = app_name, $2 = min_disk_gb, $3 = min_ram_gb, $4 = required_ports (space-separated)
preflight_check() {
    local app_name=$1
    local min_disk_gb=${2:-10}
    local min_ram_gb=${3:-2}
    local required_ports=${4:-""}
    
    local issues=0
    
    echo ""
    log_step "Pre-flight checks for $app_name"
    echo ""
    
    # Update system packages
    log_info "Updating system packages..."
    if pkg_update; then
        log_success "Package cache updated"
    else
        log_warn "Failed to update package cache, continuing anyway..."
    fi
    
    # Upgrade system packages (security updates)
    log_info "Upgrading system packages..."
    if is_debian_based; then
        # Fix broken dependencies first, then upgrade
        run_sudo apt --fix-broken install -y 2>&1 | grep -v "^Reading" || true
        run_sudo env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq 2>&1 | grep -v "^Reading" || true
    elif is_rhel_based; then
        run_sudo $PACKAGE_MANAGER upgrade -y -q 2>&1 || true
    fi
    log_success "System packages upgraded"
    echo ""
    
    # Check disk space
    local disk_available=$(get_disk_space_human)
    echo "  Disk space: $disk_available available (required: ${min_disk_gb}GB)"
    
    if ! check_disk_space "$min_disk_gb"; then
        log_warn "  [WARNING] Insufficient disk space!"
        ((issues++))
    fi
    
    # Check RAM
    local ram_available=$(get_ram_available_human)
    echo "  RAM: $ram_available available (required: ${min_ram_gb}GB)"
    
    if ! check_ram_available "$min_ram_gb"; then
        log_warn "  [WARNING] Insufficient RAM!"
        ((issues++))
    fi
    
    # Check ports
    if [ -n "$required_ports" ]; then
        echo "  Checking required ports..."
        for port in $required_ports; do
            if ! check_port_available "$port"; then
                log_warn "  [WARNING] Port $port is already in use!"
                ((issues++))
            else
                echo "    Port $port: available"
            fi
        done
    fi
    
    echo ""
    
    # Show summary
    if [ $issues -eq 0 ]; then
        log_success "All pre-flight checks passed"
    else
        log_warn "Found $issues warning(s) - installation may fail or perform poorly"
    fi
    
    # Ask user to continue
    echo ""
    read -p "Continue with installation? (y/N): " -n 1 -r confirm
    echo ""
    
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        log_info "Installation cancelled by user"
        audit_log "INSTALL_CANCELLED" "$app_name" "Pre-flight checks failed or user cancelled"
        exit 0
    fi
    
    echo ""
}

# Quick check without user prompt (for dependencies)
preflight_check_silent() {
    local app_name=$1
    local min_disk_gb=${2:-5}
    local min_ram_gb=${3:-1}
    
    local issues=0
    
    if ! check_disk_space "$min_disk_gb"; then
        ((issues++))
    fi
    
    if ! check_ram_available "$min_ram_gb"; then
        ((issues++))
    fi
    
    if [ $issues -gt 0 ]; then
        log_warn "System resources may be insufficient for $app_name"
    fi
}
