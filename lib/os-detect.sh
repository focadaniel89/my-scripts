#!/bin/bash

# ==============================================================================
# OS DETECTION & ABSTRACTION LAYER
# Provides universal functions that work across Ubuntu, Debian, AlmaLinux, etc.
# ==============================================================================

# Global variables for OS detection
OS_ID=""
OS_VERSION=""
OS_FAMILY=""
PACKAGE_MANAGER=""
OS_TYPE=""  # Alias for OS_ID

# Detect operating system
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="${VERSION_ID:-unknown}"
        
        # Determine OS family
        case "$OS_ID" in
            ubuntu|debian|linuxmint|pop)
                OS_FAMILY="debian"
                PACKAGE_MANAGER="apt"
                ;;
            rhel|centos|rocky|almalinux|fedora)
                OS_FAMILY="rhel"
                PACKAGE_MANAGER="dnf"
                # Use yum if dnf is not available
                if ! command -v dnf &>/dev/null; then
                    PACKAGE_MANAGER="yum"
                fi
                ;;
            arch|manjaro)
                OS_FAMILY="arch"
                PACKAGE_MANAGER="pacman"
                ;;
            opensuse*|sles)
                OS_FAMILY="suse"
                PACKAGE_MANAGER="zypper"
                ;;
            *)
                OS_FAMILY="unknown"
                PACKAGE_MANAGER="unknown"
                ;;
        esac
        
        # Set OS_TYPE as alias for OS_ID (backward compatibility)
        OS_TYPE="$OS_ID"
    else
        echo "ERROR: Cannot detect OS - /etc/os-release not found"
        exit 1
    fi
}

# Get OS information
get_os_info() {
    [ -z "$OS_ID" ] && detect_os
    echo "$OS_ID $OS_VERSION ($OS_FAMILY)"
}

# Check if running specific OS family
is_debian_based() {
    [ -z "$OS_FAMILY" ] && detect_os
    [ "$OS_FAMILY" = "debian" ]
}

is_rhel_based() {
    [ -z "$OS_FAMILY" ] && detect_os
    [ "$OS_FAMILY" = "rhel" ]
}

is_arch_based() {
    [ -z "$OS_FAMILY" ] && detect_os
    [ "$OS_FAMILY" = "arch" ]
}

# ==============================================================================
# PACKAGE MANAGEMENT
# ==============================================================================

# Update package index
pkg_update() {
    [ -z "$PACKAGE_MANAGER" ] && detect_os
    
    case "$PACKAGE_MANAGER" in
        apt)
            run_sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
            ;;
        dnf|yum)
            run_sudo $PACKAGE_MANAGER makecache -q
            ;;
        pacman)
            run_sudo pacman -Sy --noconfirm
            ;;
        zypper)
            run_sudo zypper refresh -q
            ;;
    esac
}

# Install packages
pkg_install() {
    local packages="$@"
    [ -z "$PACKAGE_MANAGER" ] && detect_os
    
    case "$PACKAGE_MANAGER" in
        apt)
            # Try installation with --fix-missing and retry logic
            if ! run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing $packages 2>&1; then
                log_warn "First installation attempt failed, updating cache and retrying..."
                run_sudo apt-get update --fix-missing 2>&1 || true
                run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y $packages 2>&1
            fi
            ;;
        dnf|yum)
            run_sudo $PACKAGE_MANAGER install -y -q $packages
            ;;
        pacman)
            run_sudo pacman -S --noconfirm $packages
            ;;
        zypper)
            run_sudo zypper install -y $packages
            ;;
    esac
}

# Remove packages
pkg_remove() {
    local packages="$@"
    [ -z "$PACKAGE_MANAGER" ] && detect_os
    
    case "$PACKAGE_MANAGER" in
        apt)
            run_sudo env DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq $packages
            ;;
        dnf|yum)
            run_sudo $PACKAGE_MANAGER remove -y -q $packages
            ;;
        pacman)
            run_sudo pacman -R --noconfirm $packages
            ;;
        zypper)
            run_sudo zypper remove -y $packages
            ;;
    esac
}

# Check if package is installed
pkg_is_installed() {
    local package="$1"
    [ -z "$PACKAGE_MANAGER" ] && detect_os
    
    case "$PACKAGE_MANAGER" in
        apt)
            dpkg -l "$package" 2>/dev/null | grep -q "^ii"
            ;;
        dnf|yum)
            rpm -q "$package" &>/dev/null
            ;;
        pacman)
            pacman -Q "$package" &>/dev/null
            ;;
        zypper)
            rpm -q "$package" &>/dev/null
            ;;
    esac
}

# ==============================================================================
# SERVICE MANAGEMENT
# ==============================================================================

# Get SSH service name
get_ssh_service_name() {
    [ -z "$OS_FAMILY" ] && detect_os
    
    case "$OS_FAMILY" in
        debian)
            echo "ssh"
            ;;
        rhel|arch|suse)
            echo "sshd"
            ;;
        *)
            # Try to detect which one exists
            if systemctl list-unit-files | grep -q "^ssh.service"; then
                echo "ssh"
            elif systemctl list-unit-files | grep -q "^sshd.service"; then
                echo "sshd"
            else
                echo "sshd"  # default fallback
            fi
            ;;
    esac
}

# Get firewall service name
get_firewall_service() {
    [ -z "$OS_FAMILY" ] && detect_os
    
    case "$OS_FAMILY" in
        debian)
            echo "ufw"
            ;;
        rhel)
            echo "firewalld"
            ;;
        *)
            # Detect which one is available
            if command -v ufw &>/dev/null; then
                echo "ufw"
            elif command -v firewall-cmd &>/dev/null; then
                echo "firewalld"
            else
                echo "unknown"
            fi
            ;;
    esac
}

# Start service
service_start() {
    local service_name="$1"
    run_sudo systemctl start "$service_name"
}

# Stop service
service_stop() {
    local service_name="$1"
    run_sudo systemctl stop "$service_name"
}

# Restart service
service_restart() {
    local service_name="$1"
    run_sudo systemctl restart "$service_name"
}

# Enable service on boot
service_enable() {
    local service_name="$1"
    run_sudo systemctl enable "$service_name"
}

# Check if service is active
service_is_active() {
    local service_name="$1"
    run_sudo systemctl is-active --quiet "$service_name"
}

# Check if service exists
service_exists() {
    local service_name="$1"
    run_sudo systemctl list-unit-files | grep -q "^${service_name}.service"
}

# ==============================================================================
# FIREWALL MANAGEMENT
# ==============================================================================

# Enable firewall
firewall_enable() {
    local fw_service=$(get_firewall_service)
    
    case "$fw_service" in
        ufw)
            # UFW (Ubuntu/Debian)
            ufw --force enable
            ;;
        firewalld)
            # firewalld (RHEL/CentOS/AlmaLinux)
            systemctl enable --now firewalld
            ;;
        *)
            echo "ERROR: No supported firewall found"
            return 1
            ;;
    esac
}

# Allow port
firewall_allow_port() {
    local port="$1"
    local fw_service=$(get_firewall_service)
    
    case "$fw_service" in
        ufw)
            ufw allow "$port/tcp" >/dev/null
            ;;
        firewalld)
            firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null
            firewall-cmd --reload >/dev/null
            ;;
    esac
}

# Deny port
firewall_deny_port() {
    local port="$1"
    local fw_service=$(get_firewall_service)
    
    case "$fw_service" in
        ufw)
            ufw deny "$port/tcp" >/dev/null
            ;;
        firewalld)
            firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null
            firewall-cmd --reload >/dev/null
            ;;
    esac
}

# Get firewall status
firewall_status() {
    local fw_service=$(get_firewall_service)
    
    case "$fw_service" in
        ufw)
            ufw status
            ;;
        firewalld)
            firewall-cmd --list-all
            ;;
    esac
}

# ==============================================================================
# SYSTEM UTILITIES
# ==============================================================================

# Get primary network interface
get_primary_interface() {
    ip route | grep default | awk '{print $5}' | head -n1
}

# Get primary IP address
get_primary_ip() {
    hostname -I | awk '{print $1}'
}

# Check if running as root
is_root() {
    [ "$(id -u)" -eq 0 ]
}

# Run command with sudo if not root
run_sudo() {
    if is_root; then
        "$@"
    else
        sudo "$@"
    fi
}

# ==============================================================================
# PACKAGE NAME MAPPING
# ==============================================================================

# Get package name for common tools (they differ across distributions)
get_package_name() {
    local tool="$1"
    [ -z "$OS_FAMILY" ] && detect_os
    
    case "$tool" in
        # Network tools
        netstat)
            if is_debian_based; then
                echo "net-tools"
            else
                echo "net-tools"
            fi
            ;;
        
        # Development tools
        build-essential)
            if is_debian_based; then
                echo "build-essential"
            elif is_rhel_based; then
                echo "gcc gcc-c++ make"
            elif is_arch_based; then
                echo "base-devel"
            fi
            ;;
        
        # Python
        python3-pip)
            if is_debian_based; then
                echo "python3-pip"
            elif is_rhel_based; then
                echo "python3-pip"
            elif is_arch_based; then
                echo "python-pip"
            fi
            ;;
        
        # Default: return as-is
        *)
            echo "$tool"
            ;;
    esac
}

# ==============================================================================
# INITIALIZATION
# ==============================================================================

# Auto-detect OS on source
detect_os

# Export functions for use in other scripts
export -f get_os_info
export -f is_debian_based
export -f is_rhel_based
export -f is_arch_based
export -f pkg_update
export -f pkg_install
export -f pkg_remove
export -f pkg_is_installed
export -f get_ssh_service_name
export -f get_firewall_service
export -f service_start
export -f service_stop
export -f service_restart
export -f service_enable
export -f service_is_active
export -f service_exists
export -f firewall_enable
export -f firewall_allow_port
export -f firewall_deny_port
export -f firewall_status
export -f get_primary_interface
export -f get_primary_ip
export -f is_root
export -f run_sudo
export -f get_package_name
