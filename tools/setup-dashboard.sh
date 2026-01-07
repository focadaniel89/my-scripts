#!/bin/bash
# Setup HTML Status Dashboard with Nginx Basic Auth

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Determine the actual user's home directory
# When running with sudo, use SUDO_USER; otherwise use current USER
if [ -n "${SUDO_USER:-}" ]; then
    ACTUAL_USER="$SUDO_USER"
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    ACTUAL_USER="$USER"
    ACTUAL_HOME="$HOME"
fi

# Constants
SECRETS_DIR="${ACTUAL_HOME}/.vps-secrets"
DASHBOARD_ENV="${SECRETS_DIR}/.env_dashboard"
NGINX_CONF="/etc/nginx/sites-available/dashboard"
NGINX_ENABLED="/etc/nginx/sites-enabled/dashboard"
HTML_DIR="/var/www/html"
HTPASSWD_FILE="${SECRETS_DIR}/.htpasswd"

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Check dependencies
check_dependencies() {
    log_info "Checking dependencies..."
    
    if ! command -v nginx &> /dev/null; then
        log_error "Nginx is not installed. Please install Nginx first."
        exit 1
    fi
    
    if ! command -v htpasswd &> /dev/null; then
        log_info "Installing htpasswd tools..."
        # Source OS detection for pkg_install
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        if [ -f "${SCRIPT_DIR}/lib/os-detect.sh" ]; then
            source "${SCRIPT_DIR}/lib/os-detect.sh"
            if is_debian_based; then
                pkg_install apache2-utils
            elif is_rhel_based; then
                pkg_install httpd-tools
            else
                apt-get update -qq && apt-get install -y apache2-utils
            fi
        else
            # Fallback if os-detect.sh not found
            apt-get update -qq && apt-get install -y apache2-utils
        fi
    fi
    
    log_info "Dependencies OK"
}

# Generate random password
generate_password() {
    openssl rand -base64 18 | tr -d "=+/" | cut -c1-20
}

# Create dashboard credentials
create_credentials() {
    log_info "Creating dashboard credentials..."
    
    local username="admin"
    local password=$(generate_password)
    
    # Ensure secrets directory exists with correct ownership
    mkdir -p "$SECRETS_DIR"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$SECRETS_DIR"
    chmod 700 "$SECRETS_DIR"
    
    # Create htpasswd file
    htpasswd -cb "$HTPASSWD_FILE" "$username" "$password"
    chmod 600 "$HTPASSWD_FILE"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$HTPASSWD_FILE"
    
    # Save credentials
    cat > "$DASHBOARD_ENV" << EOF
# Dashboard Access Credentials
DASHBOARD_USERNAME=$username
DASHBOARD_PASSWORD=$password
DASHBOARD_URL=http://$(hostname -I | awk '{print $1}')/status.html
EOF
    
    chmod 600 "$DASHBOARD_ENV"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$DASHBOARD_ENV"
    
    log_info "Credentials created and saved to: $DASHBOARD_ENV"
    echo ""
    echo "================================================"
    echo "  Dashboard Credentials"
    echo "================================================"
    echo "URL:      http://$(hostname -I | awk '{print $1}')/status.html"
    echo "Username: $username"
    echo "Password: $password"
    echo "================================================"
    echo ""
}

# Configure Nginx
configure_nginx() {
    log_info "Configuring Nginx..."
    
    # Create HTML directory if not exists
    mkdir -p "$HTML_DIR"
    
    # Create Nginx configuration
    cat > "$NGINX_CONF" << 'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    
    server_name _;
    root /var/www/html;
    index index.html;
    
    # Dashboard location with Basic Auth
    location = /status.html {
        auth_basic "VPS Status Dashboard";
        auth_basic_user_file HTPASSWD_PATH_PLACEHOLDER;
        try_files $uri =404;
    }
    
    # Deny access to other files
    location / {
        return 404;
    }
}
EOF
    
    # Replace htpasswd path
    sed -i "s|HTPASSWD_PATH_PLACEHOLDER|$HTPASSWD_FILE|g" "$NGINX_CONF"
    
    # Enable site
    ln -sf "$NGINX_CONF" "$NGINX_ENABLED"
    
    # Remove default site if exists
    if [ -f "/etc/nginx/sites-enabled/default" ]; then
        rm -f "/etc/nginx/sites-enabled/default"
        log_info "Removed default Nginx site"
    fi
    
    # Test Nginx configuration
    if nginx -t &> /dev/null; then
        log_info "Nginx configuration OK"
        systemctl reload nginx
        log_info "Nginx reloaded"
    else
        log_error "Nginx configuration test failed"
        nginx -t
        exit 1
    fi
}

# Generate initial dashboard
generate_dashboard() {
    log_info "Generating initial dashboard..."
    
    # Find health-check.sh script
    local health_check_script=""
    # First try relative path from script location
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "${script_dir}/health-check.sh" ]; then
        health_check_script="${script_dir}/health-check.sh"
    elif [ -f "/opt/vps-scripts/tools/health-check.sh" ]; then
        health_check_script="/opt/vps-scripts/tools/health-check.sh"
    elif [ -f "${HOME}/vps-scripts/tools/health-check.sh" ]; then
        health_check_script="${HOME}/vps-scripts/tools/health-check.sh"
    elif [ -f "./health-check.sh" ]; then
        health_check_script="./health-check.sh"
    else
        log_warn "Could not find health-check.sh script"
        log_warn "Please run manually: sudo /path/to/health-check.sh --html"
        return
    fi
    
    # Generate HTML dashboard
    bash "$health_check_script" --html "${HTML_DIR}/status.html"
    chmod 644 "${HTML_DIR}/status.html"
}

# Setup cron job for auto-refresh
setup_cron() {
    log_info "Setting up auto-refresh cron job..."
    
    # Find health-check.sh script
    local health_check_script=""
    if [ -f "/opt/vps-scripts/tools/health-check.sh" ]; then
        health_check_script="/opt/vps-scripts/tools/health-check.sh"
    elif [ -f "${HOME}/vps-scripts/tools/health-check.sh" ]; then
        health_check_script="${HOME}/vps-scripts/tools/health-check.sh"
    else
        log_warn "Could not find health-check.sh script for cron setup"
        return
    fi
    
    # Create cron job (every 2 minutes)
    local cron_job="*/2 * * * * /bin/bash $health_check_script --html ${HTML_DIR}/status.html > /dev/null 2>&1"
    
    # Check if cron job already exists
    if crontab -l 2>/dev/null | grep -q "health-check.sh --html"; then
        log_info "Cron job already exists"
    else
        (crontab -l 2>/dev/null || echo ""; echo "$cron_job") | crontab -
        log_info "Cron job created (updates every 2 minutes)"
    fi
}

# Main execution
main() {
    echo "=============================================="
    echo "  VPS Dashboard Setup"
    echo "=============================================="
    echo ""
    
    check_root
    check_dependencies
    
    # Create credentials
    create_credentials
    
    # Configure Nginx
    configure_nginx
    
    # Generate initial dashboard
    generate_dashboard
    
    # Setup cron
    setup_cron
    
    echo ""
    echo "=============================================="
    echo "  Setup Complete!"
    echo "=============================================="
    echo ""
    echo "Dashboard URL: http://$(hostname -I | awk '{print $1}')/status.html"
    echo "Credentials saved in: $DASHBOARD_ENV"
    echo ""
    echo "The dashboard will auto-update every 2 minutes."
    echo "You can manually refresh by running:"
    echo "  sudo /path/to/health-check.sh --html"
    echo ""
}

main "$@"
