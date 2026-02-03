#!/bin/bash

# ==============================================================================
# GRAFANA INSTALLATION (NATIVE)
# Installs Grafana directly on host system
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"

APP_NAME="grafana-native"
SERVICE_NAME="grafana-server"

log_info "═══════════════════════════════════════════"
log_info "  Installing Grafana (Native)"
log_info "═══════════════════════════════════════════"
echo ""

# Detect OS
log_step "Step 1: Detecting operating system"
detect_os
log_success "OS detected: $OS_TYPE"
echo ""

# Install Grafana
log_step "Step 2: Installing Grafana"

if is_debian_based; then
    install_package apt-transport-https
    install_package software-properties-common
    install_package wget
    
    # Add Grafana GPG key
    run_sudo mkdir -p /etc/apt/keyrings/
    wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | run_sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null
    
    # Add repository
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | run_sudo tee /etc/apt/sources.list.d/grafana.list
    
    update_pkg_cache
    install_package grafana
elif is_rhel_based; then
    cat <<EOF | run_sudo tee /etc/yum.repos.d/grafana.repo
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF
    install_package grafana
else
    log_error "Unsupported OS"
    exit 1
fi

log_success "Grafana installed"
echo ""

# Configure Grafana
log_step "Step 3: Configuring Grafana"

CONF_FILE="/etc/grafana/grafana.ini"
backup_file "$CONF_FILE"

# Manage admin password
ADMIN_PASS=$(get_secret "grafana-native" "GF_SECURITY_ADMIN_PASSWORD")
if [ -z "$ADMIN_PASS" ]; then
    ADMIN_PASS=$(generate_secure_password)
    save_secret "grafana-native" "GF_SECURITY_ADMIN_PASSWORD" "$ADMIN_PASS"
fi

# Pre-configure admin password via environment file for systemd
# This avoids putting cleartext password in grafana.ini
ENV_FILE="/etc/default/grafana-server"
if [ -f "/etc/sysconfig/grafana-server" ]; then
    ENV_FILE="/etc/sysconfig/grafana-server"
fi

echo "GF_SECURITY_ADMIN_PASSWORD=$ADMIN_PASS" | run_sudo tee -a "$ENV_FILE" > /dev/null
log_success "Admin password configured via environment"

# Nginx Configuration (Reverse Proxy)
log_step "Step 4: Configuring Nginx reverse proxy"

if ! command -v nginx &>/dev/null; then
    log_warn "Nginx not installed. Installing..."
    bash "${SCRIPT_DIR}/apps/infrastructure/nginx/install.sh"
fi

# Determine host/domain
# If running locally without domain, localhost is fine.
# If remote access needed, ask for domain.
GRAFANA_DOMAIN="localhost"
read -p "Enter domain for Grafana (leave empty for localhost): " INPUT_DOMAIN
if [ -n "$INPUT_DOMAIN" ]; then
    GRAFANA_DOMAIN="$INPUT_DOMAIN"
fi

NGINX_CONF="/etc/nginx/sites-available/grafana-native.conf"

run_sudo tee "$NGINX_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name $GRAFANA_DOMAIN;

    access_log /var/log/nginx/grafana_access.log;
    error_log /var/log/nginx/grafana_error.log;

    location / {
        proxy_pass http://localhost:3000;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

run_sudo ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/grafana-native.conf"

if run_sudo nginx -t; then
    run_sudo systemctl reload nginx
    log_success "Nginx confiugred"
else
    log_error "Nginx configuration failed"
fi
echo ""

# Start Service
log_step "Step 5: Starting Grafana"
run_sudo systemctl enable "$SERVICE_NAME"
run_sudo systemctl restart "$SERVICE_NAME"

if systemctl is-active --quiet "$SERVICE_NAME"; then
    log_success "Grafana started successfully"
else
    log_error "Failed to start Grafana"
    exit 1
fi
echo ""

log_success "═══════════════════════════════════════════"
log_success "  Grafana Installation Complete!"
log_success "═══════════════════════════════════════════"
echo "  URL: http://$GRAFANA_DOMAIN"
echo "  Admin User: admin"
echo "  Admin Pass: $ADMIN_PASS"
echo "  Service: sudo systemctl status $SERVICE_NAME"
echo ""
