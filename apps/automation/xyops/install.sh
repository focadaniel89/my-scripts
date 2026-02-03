#!/bin/bash

# ==============================================================================
# XYOPS INSTALLATION (NATIVE)
# Setup XyOps with Node.js and Systemd service
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"

APP_NAME="xyops"
INSTALL_DIR="/opt/automation/xyops"
REPO_URL="https://github.com/pixlcore/xyops.git"
SERVICE_NAME="xyops"

log_info "═══════════════════════════════════════════"
log_info "  Installing XyOps (Native)"
log_info "═══════════════════════════════════════════"
echo ""

# Detect OS
log_step "Step 1: Detecting operating system"
detect_os
log_success "OS detected: $OS_TYPE"
echo ""

# Check dependencies
log_step "Step 2: Checking dependencies"
install_package git
install_package curl

# Install Node.js if missing
if ! command -v node &>/dev/null; then
    log_info "Installing Node.js..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | run_sudo bash -
    install_package nodejs
fi
log_success "Node.js version: $(node -v)"

# Nginx check
if ! command -v nginx &>/dev/null; then
    log_warn "Nginx not installed. Installing..."
    bash "${SCRIPT_DIR}/apps/infrastructure/nginx/install.sh"
fi
echo ""

# Create installation directory
log_step "Step 3: Setting up directory"
if [ ! -d "$INSTALL_DIR" ]; then
    run_sudo mkdir -p "$INSTALL_DIR"
    run_sudo chown -R $USER:$USER "$INSTALL_DIR"
    log_success "Created directory: $INSTALL_DIR"
else
    log_info "Directory exists: $INSTALL_DIR"
fi
echo ""

# Clone Repository
log_step "Step 4: Cloning XyOps"
if [ ! -d "${INSTALL_DIR}/.git" ]; then
    git clone "$REPO_URL" "$INSTALL_DIR"
    log_success "Cloned repository"
else
    log_info "Repository already cloned"
    cd "$INSTALL_DIR"
    git pull
fi

# Install NPM dependencies
log_step "Step 5: Installing NPM dependencies"
cd "$INSTALL_DIR"
npm install
log_success "Dependencies installed"
echo ""

# Configure XyOps
log_step "Step 6: Configuring XyOps"
if [ ! -f "conf/config.json" ]; then
    # Create conf dir if missing (should exist from repo structure but just in case)
    mkdir -p conf
    
    # Copy sample config
    if [ -f "sample_conf/config.json" ]; then
        cp sample_conf/config.json conf/config.json
        log_success "Created config.json from sample"
        
        # Determine secret key
        SECRET_KEY=$(get_secret "$APP_NAME" "XYOPS_SECRET_KEY")
        if [ -z "$SECRET_KEY" ]; then
             SECRET_KEY=$(openssl rand -hex 32)
             save_secret "$APP_NAME" "XYOPS_SECRET_KEY" "$SECRET_KEY"
        fi
        
        # Update secret key in config
        sed -i "s|\"secret_key\": \"initial\"|\"secret_key\": \"$SECRET_KEY\"|" conf/config.json
        log_info "Updated secret key in configuration"
    else
        log_error "Sample config not found!"
        exit 1
    fi
fi
echo ""

# Create Systemd Service
log_step "Step 7: Creating Systemd Service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

run_sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=XyOps Workflow Automation
After=network.target

[Service]
# Use forking because control.sh starts a daemon and exits
Type=forking
User=$USER
WorkingDirectory=$INSTALL_DIR
ExecStart=${INSTALL_DIR}/bin/control.sh start
ExecStop=${INSTALL_DIR}/bin/control.sh stop
PIDFile=${INSTALL_DIR}/logs/xyops.pid
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

run_sudo systemctl daemon-reload
run_sudo systemctl enable "$SERVICE_NAME"

# Note: XyOps control script might fork, using 'simple' with control.sh might be tricky.
# Usually 'forking' is better if control.sh handles pid files properly.
# However, for simplicity and ensuring we capture logs, running `node lib/main.js` might be better if control.sh is a wrapper.
# Let's check package.json start script: "bin/control.sh start"
# Let's try to start it.

# Stop if running
${INSTALL_DIR}/bin/control.sh stop || true

# Start via systemd
run_sudo systemctl start "$SERVICE_NAME"

if systemctl is-active --quiet "$SERVICE_NAME"; then
    log_success "Service started: $SERVICE_NAME"
else
    log_warn "Service failed to start via systemd, trying manual start to debug..."
    ${INSTALL_DIR}/bin/control.sh start
    if [ $? -eq 0 ]; then
        log_success "Started manually"
    else
        log_error "Failed to start XyOps"
        exit 1
    fi
fi
echo ""

# Configure Nginx
log_step "Step 8: Configuring Nginx"

DOMAIN=""
if [ -f "${HOME}/.vps-secrets/.env_xyops" ]; then
    DOMAIN=$(grep "DOMAIN=" "${HOME}/.vps-secrets/.env_xyops" | cut -d= -f2)
fi

if [ -z "$DOMAIN" ]; then
    read -p "Enter domain for XyOps (e.g. ops.example.com): " DOMAIN
    save_secret "xyops" "DOMAIN" "$DOMAIN"
fi

NGINX_CONF="/etc/nginx/sites-available/$APP_NAME.conf"

run_sudo tee "$NGINX_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    access_log /var/log/nginx/${APP_NAME}_access.log;
    error_log /var/log/nginx/${APP_NAME}_error.log;

    location / {
        proxy_pass http://127.0.0.1:5522;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

run_sudo ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/$APP_NAME.conf"

if run_sudo nginx -t; then
    run_sudo systemctl reload nginx
    log_success "Nginx configured"
else
    log_error "Nginx configuration failed"
fi
echo ""

log_success "═══════════════════════════════════════════"
log_success "  XyOps Installation Complete!"
log_success "═══════════════════════════════════════════"
echo "  URL: http://$DOMAIN"
echo "  Path: $INSTALL_DIR"
echo ""
