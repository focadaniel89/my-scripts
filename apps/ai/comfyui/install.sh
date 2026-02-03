#!/bin/bash

# ==============================================================================
# COMFYUI INSTALLATION (NATIVE)
# Setup ComfyUI with Python venv and Systemd service
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"

APP_NAME="comfyui"
INSTALL_DIR="/opt/ai/comfyui"
REPO_URL="https://github.com/comfyanonymous/ComfyUI.git"
VENV_DIR="${INSTALL_DIR}/venv"
SERVICE_NAME="comfyui"

log_info "═══════════════════════════════════════════"
log_info "  Installing ComfyUI (Native)"
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
install_package python3
install_package python3-venv
install_package python3-pip
install_package ffmpeg

# Nginx check
if ! command -v nginx &>/dev/null; then
    log_warn "Nginx not installed. Installing..."
    bash "${SCRIPT_DIR}/apps/infrastructure/nginx/install.sh"
fi
log_success "Dependencies checked"
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

# Setup Python Venv
log_step "Step 4: Setting up Python Environment"
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
    log_success "Created virtual environment"
fi

# Activate and install comfy-cli
log_step "Step 5: Installing Comfy-CLI and ComfyUI"
source "${VENV_DIR}/bin/activate"
pip install --upgrade pip
log_info "Installing comfy-cli..."
pip install comfy-cli

# Install ComfyUI using CLI
# This will install into ${INSTALL_DIR}/ComfyUI
log_info "Installing ComfyUI via CLI..."
if [ ! -d "${INSTALL_DIR}/ComfyUI" ]; then
    # Install with NVIDIA support (defaulting to standard cuda)
    comfy --workspace "${INSTALL_DIR}" install --nvidia
    log_success "ComfyUI installed via CLI"
else
    log_info "ComfyUI directory already exists, updating..."
    # We need to be inside the workspace to update or specify it
    cd "${INSTALL_DIR}/ComfyUI"
    git pull
    # Restore/Update dependencies
    comfy --workspace "${INSTALL_DIR}" install --restore
fi
echo ""

# Create Systemd Service
log_step "Step 6: Creating Systemd Service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
# Path to ComfyUI code is now inside the 'ComfyUI' subdirectory
COMFY_CODE_DIR="${INSTALL_DIR}/ComfyUI"

run_sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=ComfyUI AI Image Generation
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$COMFY_CODE_DIR
Environment=PATH=${VENV_DIR}/bin:/usr/local/bin:/usr/bin:/bin
# Performance optimizations:
# --use-pytorch-cross-attention: Reduces VRAM usage and improves speed
# --preview-method auto: Efficient preview generation
ExecStart=${VENV_DIR}/bin/python main.py --listen 127.0.0.1 --port 8188 --use-pytorch-cross-attention --preview-method auto
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

run_sudo systemctl daemon-reload
run_sudo systemctl enable "$SERVICE_NAME"
run_sudo systemctl restart "$SERVICE_NAME"

if systemctl is-active --quiet "$SERVICE_NAME"; then
    log_success "Service started: $SERVICE_NAME"
else
    log_error "Failed to start service"
    exit 1
fi
echo ""

# Configure Nginx
log_step "Step 7: Configuring Nginx"

DOMAIN=""
if [ -f "${HOME}/.vps-secrets/.env_comfyui" ]; then
    DOMAIN=$(grep "DOMAIN=" "${HOME}/.vps-secrets/.env_comfyui" | cut -d= -f2)
fi

if [ -z "$DOMAIN" ]; then
    read -p "Enter domain for ComfyUI (e.g. comfy.example.com): " DOMAIN
    save_secret "comfyui" "DOMAIN" "$DOMAIN"
fi

NGINX_CONF="/etc/nginx/sites-available/$APP_NAME.conf"

run_sudo tee "$NGINX_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    access_log /var/log/nginx/${APP_NAME}_access.log;
    error_log /var/log/nginx/${APP_NAME}_error.log;

    location / {
        proxy_pass http://127.0.0.1:8188;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
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
log_success "  ComfyUI Installation Complete!"
log_success "═══════════════════════════════════════════"
echo "  URL: http://$DOMAIN"
echo "  Service: sudo systemctl status $SERVICE_NAME"
echo "  Path: $INSTALL_DIR"
echo ""
