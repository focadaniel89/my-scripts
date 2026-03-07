#!/bin/bash

# ==============================================================================
# SHARED UTILITIES LIBRARY
# Common functions for logging, sudo handling, OS detection, and system operations
# ==============================================================================

set -euo pipefail

# --- COLORS FOR LOGGING ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# --- AUDIT LOGGING ---
AUDIT_LOG="${HOME}/.vps-secrets/.audit.log"

# Initialize audit log
init_audit_log() {
    local secrets_dir="${HOME}/.vps-secrets"
    
    if [ ! -d "$secrets_dir" ]; then
        mkdir -p "$secrets_dir"
        chmod 700 "$secrets_dir"
    fi
    
    if [ ! -f "$AUDIT_LOG" ]; then
        touch "$AUDIT_LOG"
        chmod 600 "$AUDIT_LOG"
    fi
}

# Write audit log entry
# Args: $1 = action, $2 = app_name, $3 = details (optional), $4 = result (SUCCESS/FAILED)
audit_log() {
    local action=$1
    local app_name=${2:-"system"}
    local details=${3:-""}
    local result=${4:-"SUCCESS"}
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local user=${SUDO_USER:-$(whoami)}
    
    init_audit_log
    
    if [ -n "$details" ]; then
        echo "[$timestamp] $action $app_name by $user - $details - $result" >> "$AUDIT_LOG"
    else
        echo "[$timestamp] $action $app_name by $user - $result" >> "$AUDIT_LOG"
    fi
}

# --- LOGGING FUNCTIONS ---
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_step() {
    echo -e "${BLUE}>>> $1${NC}"
}

log_debug() {
    if [ "${DEBUG:-0}" = "1" ]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

# --- USER CONFIRMATION ---
# Prompt user for confirmation
# Set FORCE_YES=1 environment variable to skip all confirmations
confirm_action() {
    local prompt=${1:-"Continue?"}
    
    # Check if we're in automation mode
    if [ "${FORCE_YES:-0}" = "1" ] || [ "${CI:-}" = "true" ]; then
        log_info "$prompt [AUTO-YES]"
        return 0
    fi
    
    # Interactive mode (default)
    echo -ne "${YELLOW}$prompt (y/N):${NC} "
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# --- UTILITY GUARDS ---

# Warn (not block) if not running on Debian/Ubuntu.
# Call require_debian() at top of Debian-specific scripts for a clear message.
require_debian() {
    if ! is_debian_based 2>/dev/null; then
        log_warn "This script is designed for Debian/Ubuntu."
        log_warn "Current OS may not be fully supported. Continuing anyway..."
    fi
}

# Check minimum bash version (we use bash 4 features: associative arrays, etc.)
check_min_bash_version() {
    local required_major=${1:-4}
    local actual_major="${BASH_VERSINFO[0]}"
    if [ "$actual_major" -lt "$required_major" ]; then
        log_error "Bash $required_major+ required. Current: $BASH_VERSION"
        return 1
    fi
    return 0
}

# Check internet connectivity (3-second timeout)
check_internet() {
    if ping -c 1 -W 3 8.8.8.8 &>/dev/null 2>&1 || \
       curl -s --max-time 3 https://google.com &>/dev/null 2>&1; then
        return 0
    fi
    log_warn "No internet connectivity detected"
    return 1
}

# Return correct SSH service name for current distro
# Debian/Ubuntu: ssh  |  RHEL/Fedora: sshd
get_ssh_service_name() {
    if is_debian_based 2>/dev/null; then
        echo "ssh"
    else
        echo "sshd"
    fi
}


# Ensure service is running, start if needed
# Args: $1 = service_name, $2 = friendly_name (optional)
ensure_service_running() {
    local service_name=$1
    local friendly_name=${2:-$service_name}
    
    if run_sudo systemctl is-active --quiet "$service_name" 2>/dev/null; then
        log_debug "$friendly_name is already running"
        return 0
    fi
    
    log_info "$friendly_name is not running, starting it..."
    if run_sudo systemctl start "$service_name" 2>/dev/null; then
        run_sudo systemctl enable "$service_name" 2>/dev/null || true
        log_success "$friendly_name started"
        sleep 2  # Wait for service to be ready
        return 0
    else
        log_error "Failed to start $friendly_name"
        return 1
    fi
}

# Check if service exists
service_exists() {
    local service_name=$1
    systemctl list-unit-files "$service_name.service" &>/dev/null
}

# --- SUDO WRAPPER ---
# Executes commands with root privileges
# Priority: 1) User is root, 2) SUDO_PASS env var, 3) Interactive/passwordless sudo
run_sudo() {
    # If we are root, run directly
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
        return $?
    fi
    
    # Special case: docker commands when user is in docker group
    # Check if first argument is 'docker' and user has docker group access
    if [ "$1" = "docker" ]; then
        # Check if user is in docker group (or if we just added them)
        if groups 2>/dev/null | grep -q docker || [ "${DOCKER_GROUP_ACTIVATED:-0}" = "1" ]; then
            # Try running docker without sudo first
            if "$@" 2>/dev/null; then
                return $?
            fi
            # If it fails, fall through to sudo method below
        fi
    fi

    # If SUDO_PASS is provided (automation)
    if [ -n "${SUDO_PASS:-}" ]; then
        echo "$SUDO_PASS" | sudo -S -p "" "$@" 2>/dev/null
        return $?
    fi

    # Try passwordless sudo or interactive sudo
    if sudo -n true 2>/dev/null; then
        sudo "$@"
    else
        if [ -t 0 ]; then
            sudo "$@"
        else
            log_error "Root privileges required. Please set SUDO_PASS or run as root."
            exit 1
        fi
    fi
}

# --- OS DETECTION ---
# Sets global variables: OS_NAME, OS_VERSION, PACKAGE_MANAGER
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME=$ID
        OS_VERSION=$VERSION_ID
    else
        log_error "Cannot detect OS. /etc/os-release file is missing."
        exit 1
    fi

    case "$OS_NAME" in
        ubuntu|debian|pop|linuxmint|kali)
            PACKAGE_MANAGER="apt"
            ;;
        centos|rhel|fedora|almalinux|rocky|ol)
            PACKAGE_MANAGER="yum"
            ;;
        *)
            if [[ "${ID_LIKE:-}" == *"debian"* ]]; then
                PACKAGE_MANAGER="apt"
            elif [[ "${ID_LIKE:-}" == *"rhel"* ]] || [[ "${ID_LIKE:-}" == *"fedora"* ]]; then
                PACKAGE_MANAGER="yum"
            else
                log_warn "Unknown OS ($OS_NAME). Defaulting to 'apt'."
                PACKAGE_MANAGER="apt"
            fi
            ;;
    esac

    log_debug "Detected OS: $OS_NAME $OS_VERSION | Package Manager: $PACKAGE_MANAGER"
}

# --- FIREWALL MANAGER ---
# Automatically detects and configures UFW or Firewalld
open_port() {
    local port=$1
    local comment=$2
    local proto=${3:-tcp}

    if [ -z "$port" ]; then
        log_error "open_port: Port number required"
        return 1
    fi

    log_info "Opening firewall port: $port/$proto ($comment)"

    # Check for UFW
    if command -v ufw >/dev/null 2>&1; then
        if run_sudo ufw status 2>/dev/null | grep -q "Status: active"; then
            run_sudo ufw allow "$port/$proto" comment "$comment" 2>/dev/null
            log_info "Port opened in UFW"
            return 0
        fi
    fi

    # Check for Firewalld
    if command -v firewall-cmd >/dev/null 2>&1; then
        if systemctl is-active --quiet firewalld 2>/dev/null; then
            run_sudo firewall-cmd --permanent --add-port="$port/$proto" >/dev/null 2>&1
            run_sudo firewall-cmd --reload >/dev/null 2>&1
            log_info "Port opened in Firewalld"
            return 0
        fi
    fi

    log_warn "No active firewall detected. Ensure port $port is accessible."
}

# --- PACKAGE INSTALLATION ---
# Install package if not already present
install_package() {
    local package=$1
    
    if command -v "$package" &> /dev/null; then
        log_debug "Package already installed: $package"
        return 0
    fi
    
    log_info "Installing package: $package"
    detect_os
    
    case "$PACKAGE_MANAGER" in
        apt)
            run_sudo apt-get update -qq
            run_sudo apt-get install -y "$package"
            ;;
        yum)
            run_sudo yum install -y "$package"
            ;;
        *)
            log_error "Unsupported package manager: $PACKAGE_MANAGER"
            return 1
            ;;
    esac
}

# --- DEPENDENCY CHECKER ---
# Check if a dependency (app) is installed
# Args: $1 = app category/name (e.g., "infrastructure/docker-engine")
require_dependency() {
    local dep_path=$1
    local app_name=$(basename "$dep_path")
    
    log_info "Checking dependency: $app_name"
    
    # Basic checks for common dependencies
    case "$app_name" in
        docker-engine|docker)
            if ! command -v docker &> /dev/null; then
                log_error "Docker not installed. Please install Docker first."
                log_info "Run: Select Infrastructure > Docker Engine from main menu"
                return 1
            fi
            if ! docker info &> /dev/null; then
                log_error "Docker is installed but not running"
                return 1
            fi
            log_success "Docker is available"
            return 0
            ;;
        postgres|postgresql)
            if ! docker ps --format '{{.Names}}' | grep -q "postgres"; then
                log_error "PostgreSQL container not running"
                log_info "Run: Select Databases > PostgreSQL from main menu"
                return 1
            fi
            log_success "PostgreSQL is available"
            return 0
            ;;
        nginx)
            if ! command -v nginx &> /dev/null && ! docker ps --format '{{.Names}}' | grep -q "nginx"; then
                log_error "Nginx not installed"
                return 1
            fi
            log_success "Nginx is available"
            return 0
            ;;
        *)
            log_warn "Unknown dependency: $app_name (skipping check)"
            return 0
            ;;
    esac
}

# --- SYSTEM CHECKS ---
# Check system requirements
check_system_requirements() {
    log_info "Checking system requirements..."
    
    # Check if running on Linux
    if [[ "$(uname)" != "Linux" ]]; then
        log_error "This script requires Linux"
        return 1
    fi
    
    # Check required commands
    local required_commands=("curl" "wget" "tar" "grep" "sed" "awk")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_warn "Required command not found: $cmd"
            install_package "$cmd"
        fi
    done
    
    log_success "System requirements check passed"
    return 0
}

# --- DIRECTORY MANAGEMENT ---
# Create directory with proper permissions
create_app_directory() {
    local dir_path=$1
    local permissions=${2:-755}
    
    if [ -d "$dir_path" ]; then
        log_debug "Directory already exists: $dir_path"
        return 0
    fi
    
    log_info "Creating directory: $dir_path"
    run_sudo mkdir -p "$dir_path"
    run_sudo chmod "$permissions" "$dir_path"
    
    return 0
}

# --- FILE OPERATIONS ---
# Backup a file before modification
backup_file() {
    local file_path=$1
    
    if [ ! -f "$file_path" ]; then
        log_warn "File not found for backup: $file_path"
        return 1
    fi
    
    local backup_path="${file_path}.backup_$(date +%Y%m%d_%H%M%S)"
    run_sudo cp "$file_path" "$backup_path"
    log_info "File backed up to: $backup_path"
}

# --- SERVICE MANAGEMENT ---
# Enable and start a systemd service
enable_service() {
    local service_name=$1
    
    log_info "Enabling service: $service_name"
    run_sudo systemctl enable "$service_name" 2>/dev/null
    run_sudo systemctl start "$service_name" 2>/dev/null
    
    if systemctl is-active --quiet "$service_name"; then
        log_success "Service started: $service_name"
        return 0
    else
        log_error "Failed to start service: $service_name"
        return 1
    fi
}

# Check if service is running
check_service() {
    local service_name=$1
    
    if systemctl is-active --quiet "$service_name"; then
        return 0
    else
        return 1
    fi
}

# --- NETWORK OPERATIONS ---
# Check if a URL is reachable
check_url() {
    local url=$1
    local max_attempts=${2:-3}
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if curl -sSf -o /dev/null "$url" 2>/dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    
    return 1
}

# Get public IP address
get_public_ip() {
    local ip=$(curl -s ifconfig.me 2>/dev/null)
    if [ -z "$ip" ]; then
        ip=$(curl -s api.ipify.org 2>/dev/null)
    fi
    echo "$ip"
}

# --- ERROR HANDLING ---
# Error handler for scripts
error_exit() {
    local error_msg=$1
    local exit_code=${2:-1}
    
    log_error "$error_msg"
    exit "$exit_code"
}

# Trap errors
setup_error_trap() {
    trap 'error_exit "Script failed at line $LINENO"' ERR
}

# --- CLEANUP ---
# Cleanup temporary files
cleanup_temp_files() {
    local temp_dir="/tmp/vps-orchestrator-$$"
    
    if [ -d "$temp_dir" ]; then
        rm -rf "$temp_dir"
        log_debug "Cleaned up temporary files"
    fi
}

# Register cleanup on exit
register_cleanup() {
    trap cleanup_temp_files EXIT
}

# --- SECURITY HARDENING UTILITIES (Debian/Ubuntu) ---

# Harden sudo: 5-min password timeout + full command logging
configure_sudo_security() {
    if ! is_debian_based 2>/dev/null; then
        log_warn "configure_sudo_security: Debian/Ubuntu only, skipping"
        return 0
    fi

    log_info "Hardening sudo configuration..."

    run_sudo bash -c "cat > /etc/sudoers.d/99-hardening" <<'EOF'
# Re-ask password every 5 minutes (default is 15)
Defaults timestamp_timeout=5

# Log all sudo commands (I/O capture)
Defaults logfile=/var/log/sudo.log
Defaults log_input,log_output

# Prevent PATH hijacking
Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
    run_sudo chmod 440 /etc/sudoers.d/99-hardening

    # Weekly log rotation to avoid disk fill
    run_sudo bash -c "cat > /etc/logrotate.d/sudo-log" <<'EOF'
/var/log/sudo.log {
    weekly
    rotate 12
    compress
    missingok
    notifempty
}
EOF
    log_success "sudo hardened: 5-min timeout + logging → /var/log/sudo.log"
}

# Enable AppArmor and enforce all shipped profiles (Debian/Ubuntu)
enable_apparmor() {
    if ! is_debian_based 2>/dev/null; then
        log_warn "enable_apparmor: Debian/Ubuntu only, skipping"
        return 0
    fi

    log_info "Configuring AppArmor..."

    if ! dpkg -l apparmor &>/dev/null 2>&1; then
        pkg_install apparmor apparmor-utils apparmor-profiles apparmor-profiles-extra
    fi

    run_sudo systemctl enable apparmor
    run_sudo systemctl start apparmor

    if command -v aa-enforce &>/dev/null; then
        run_sudo aa-enforce /etc/apparmor.d/* 2>/dev/null || true
        log_success "AppArmor enabled — profiles set to enforce"
    else
        log_warn "aa-enforce not found; AppArmor started but profiles not enforced"
    fi
}

# --- INITIALIZATION ---
# Initialize logging directory
init_logging() {
    local log_dir="${HOME}/.vps-orchestrator/logs"
    
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir"
        chmod 700 "$log_dir"
    fi
    
    export LOG_FILE="${log_dir}/orchestrator_$(date +%Y%m%d).log"
}

# Log to file (in addition to console)
log_to_file() {
    if [ -n "${LOG_FILE:-}" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
    fi
}

# --- TEMPLATE PROCESSING ---
# Replace variables in template file
# Args: $1 = template_file, $2 = output_file, $3... = KEY=VALUE pairs
process_template() {
    local template_file=$1
    local output_file=$2
    shift 2
    
    if [ ! -f "$template_file" ]; then
        log_error "Template not found: $template_file"
        return 1
    fi
    
    local temp_file=$(mktemp)
    cp "$template_file" "$temp_file"
    
    # Replace each KEY=VALUE pair
    for pair in "$@"; do
        local key="${pair%%=*}"
        local value="${pair#*=}"
        sed -i "s|{{${key}}}|${value}|g" "$temp_file"
    done
    
    mv "$temp_file" "$output_file"
    log_info "Template processed: $output_file"
}

export -f configure_sudo_security
export -f enable_apparmor
export -f require_debian
export -f check_min_bash_version
export -f check_internet
export -f get_ssh_service_name

# --- INPUT PROMPTS ---

# Prompt user for a valid domain name and assign to a variable
# Args: $1 = variable name to set (default: DOMAIN)
# Usage: prompt_domain N8N_DOMAIN
prompt_domain() {
    local var_name=${1:-DOMAIN}
    while true; do
        read -rp "Enter domain name: " _domain_val
        _domain_val=$(echo "$_domain_val" | xargs)
        if [ -z "$_domain_val" ]; then
            log_error "Domain cannot be empty"
            continue
        fi
        if [[ ! "$_domain_val" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
            log_error "Invalid domain format (e.g. app.example.com)"
            continue
        fi
        log_success "Domain: $_domain_val"
        printf -v "$var_name" '%s' "$_domain_val"
        break
    done
}

# Prompt user for a valid email address and assign to a variable
# Args: $1 = variable name to set (default: EMAIL)
# Usage: prompt_email N8N_EMAIL
prompt_email() {
    local var_name=${1:-EMAIL}
    while true; do
        read -rp "Enter email address: " _email_val
        _email_val=$(echo "$_email_val" | xargs)
        if [ -z "$_email_val" ]; then
            log_error "Email cannot be empty"
            continue
        fi
        if [[ ! "$_email_val" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            log_error "Invalid email format (e.g. admin@example.com)"
            continue
        fi
        log_success "Email: $_email_val"
        printf -v "$var_name" '%s' "$_email_val"
        break
    done
}

# --- NGINX HELPERS ---

# Write a standard reverse-proxy Nginx site config with WebSocket support
# Args: $1=app_name, $2=domain, $3=upstream_port, $4=extra_location_block (optional)
# Creates: /etc/nginx/sites-available/{app_name}.conf + symlink in sites-enabled
write_nginx_proxy_config() {
    local app_name=$1
    local domain=$2
    local upstream_port=$3
    local extra_block=${4:-""}
    local conf_path="/etc/nginx/sites-available/${app_name}.conf"

    log_info "Writing Nginx reverse-proxy config for $domain → localhost:$upstream_port"

    run_sudo tee "$conf_path" > /dev/null <<EOF
# ${app_name} — Nginx Reverse Proxy
# Domain: ${domain}
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    include snippets/security.conf;

    access_log /var/log/nginx/${app_name}_access.log;
    error_log  /var/log/nginx/${app_name}_error.log warn;

    # Let's Encrypt ACME challenge
    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root /var/www/html;
    }

    location / {
        proxy_pass http://127.0.0.1:${upstream_port};
        proxy_http_version 1.1;

        # WebSocket support
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # Standard proxy headers
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host  \$host;
        proxy_set_header X-Forwarded-Port  \$server_port;

        proxy_connect_timeout 300s;
        proxy_send_timeout    300s;
        proxy_read_timeout    300s;

        proxy_buffering         off;
        proxy_request_buffering off;
        proxy_hide_header X-Powered-By;
    }

    # Deny hidden files except ACME challenge
    location ~ /\\.(?!well-known).* {
        deny all;
        access_log off;
        log_not_found off;
    }

    ${extra_block}
}
EOF

    run_sudo ln -sf "$conf_path" "/etc/nginx/sites-enabled/${app_name}.conf"
    log_success "Nginx config written and enabled: $conf_path"
}

# Rewrite Nginx site config with SSL (for use after certificate is issued)
# Args: $1=app_name, $2=domain, $3=upstream_port
write_nginx_ssl_config() {
    local app_name=$1
    local domain=$2
    local upstream_port=$3
    local conf_path="/etc/nginx/sites-available/${app_name}.conf"

    log_info "Rewriting Nginx config with SSL for $domain"

    run_sudo tee "$conf_path" > /dev/null <<EOF
# ${app_name} — Nginx Reverse Proxy with SSL
# Domain: ${domain}
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${domain};

    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;

    include snippets/ssl-params.conf;
    include snippets/security.conf;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

    access_log /var/log/nginx/${app_name}_access.log;
    error_log  /var/log/nginx/${app_name}_error.log warn;

    location / {
        proxy_pass http://127.0.0.1:${upstream_port};
        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host  \$host;
        proxy_set_header X-Forwarded-Port  \$server_port;

        proxy_connect_timeout 300s;
        proxy_send_timeout    300s;
        proxy_read_timeout    300s;

        proxy_buffering         off;
        proxy_request_buffering off;
        proxy_hide_header X-Powered-By;
    }

    location ~ /\\.(?!well-known).* {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF

    run_sudo ln -sf "$conf_path" "/etc/nginx/sites-enabled/${app_name}.conf"
    log_success "SSL Nginx config written: $conf_path"
}

# --- SSL CERTIFICATE SETUP ---

# Request Let's Encrypt or self-signed SSL certificate, then rewrite nginx config with SSL
# Args: $1=domain, $2=email, $3=app_name, $4=upstream_port
# Requires: write_nginx_ssl_config() and SCRIPT_DIR to be set in calling script
setup_ssl_certificate() {
    local domain=$1
    local email=$2
    local app_name=$3
    local upstream_port=$4
    local cert_path="/etc/letsencrypt/live/${domain}"

    log_step "SSL Certificate Setup for: $domain"
    echo ""

    # Already exists — skip
    if run_sudo test -d "$cert_path" && run_sudo test -f "$cert_path/fullchain.pem"; then
        log_success "SSL certificate already exists for $domain"
        write_nginx_ssl_config "$app_name" "$domain" "$upstream_port"
        run_sudo nginx -t && run_sudo systemctl reload nginx
        return 0
    fi

    log_info "Choose SSL certificate type:"
    echo "  1) Let's Encrypt (certbot) — Free, trusted, auto-renewable"
    echo "  2) Self-signed              — Quick, no DNS required, Cloudflare compatible"
    echo ""
    read -rp "Enter choice [1-2]: " CERT_CHOICE
    echo ""

    case $CERT_CHOICE in
        1)
            log_info "Using Let's Encrypt (certbot)"

            if ! command -v certbot &>/dev/null; then
                log_warn "Certbot not installed, installing now..."
                local certbot_installer="${SCRIPT_DIR}/apps/infrastructure/certbot/install.sh"
                if [ -f "$certbot_installer" ]; then
                    bash "$certbot_installer"
                else
                    log_error "Certbot installer not found: $certbot_installer"
                    return 1
                fi
            fi

            log_warn "Ensure DNS for $domain points to this server: $(hostname -I | awk '{print $1}')"
            echo ""

            local cert_log="/var/log/my-scripts/certbot_${app_name}_$(date +%Y%m%d_%H%M%S).log"
            run_sudo mkdir -p "$(dirname "$cert_log")"

            set +e
            run_sudo certbot --nginx -d "$domain" \
                --email "$email" \
                --agree-tos --no-eff-email --redirect --non-interactive \
                2>&1 | run_sudo tee "$cert_log"
            local exit_code=${PIPESTATUS[0]}
            set -e

            if [ "$exit_code" -eq 0 ]; then
                log_success "Let's Encrypt certificate issued for $domain"
                audit_log "SSL_CONFIGURED" "$app_name" "Domain: $domain"
            elif grep -q "too many certificates\|rate limit" "$cert_log" 2>/dev/null; then
                log_warn "Let's Encrypt rate limit hit — falling back to self-signed"
                _generate_self_signed "$domain" "$app_name"
            else
                log_error "certbot failed (exit $exit_code). Check: $cert_log"
                return 1
            fi
            ;;
        2)
            log_info "Using self-signed certificate"
            _generate_self_signed "$domain" "$app_name"
            ;;
        *)
            log_error "Invalid choice"
            return 1
            ;;
    esac

    # Rewrite nginx config with SSL and reload
    write_nginx_ssl_config "$app_name" "$domain" "$upstream_port"
    if run_sudo nginx -t; then
        run_sudo systemctl reload nginx
        log_success "Nginx reloaded with SSL"
    else
        log_error "Nginx config invalid after SSL setup"
        return 1
    fi
}

# Internal helper: generate a self-signed certificate via tools script
_generate_self_signed() {
    local domain=$1
    local app_name=$2
    local gen_script="${SCRIPT_DIR}/tools/generate-self-signed-cert.sh"

    if [ -f "$gen_script" ]; then
        bash "$gen_script" "$domain"
        log_success "Self-signed certificate created for $domain"
        log_warn "Set Cloudflare SSL to 'Full' (not 'Full Strict') if using Cloudflare"
        audit_log "SSL_SELF_SIGNED" "$app_name" "Domain: $domain"
    else
        log_error "Self-signed cert generator not found: $gen_script"
        return 1
    fi
}

export -f prompt_domain prompt_email
export -f write_nginx_proxy_config write_nginx_ssl_config
export -f setup_ssl_certificate _generate_self_signed

