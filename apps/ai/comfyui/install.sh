#!/bin/bash

# ==============================================================================
# COMFYUI INSTALLATION (NATIVE & RUNPOD OPTIMIZED)
# Setup ComfyUI with Python venv, optimized for RunPod persistence users.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
# We might not have secrets on a fresh RunPod, so we conditionally source or just rely on local env
if [ -f "${SCRIPT_DIR}/lib/secrets.sh" ]; then
    source "${SCRIPT_DIR}/lib/secrets.sh"
fi
source "${SCRIPT_DIR}/lib/os-detect.sh"

APP_NAME="comfyui"

# ------------------------------------------------------------------------------
# ENVIRONMENT DETECTION
# ------------------------------------------------------------------------------
# We check for systemd to decide between "Native VPS" mode and "Container/RunPod" mode.
# SimplePod VPS instances have systemd, so they will be treated as Native.
# RunPod containers usually do not have working systemd.

IS_CONTAINER=false
HAS_SYSTEMD=false

if pidof systemd >/dev/null 2>&1 || [ "$(ps --no-headers -o comm 1 2>/dev/null)" == "systemd" ]; then
    HAS_SYSTEMD=true
fi

# RunPod check matches standard RunPod env vars or lack of systemd with workspace
if [ "$HAS_SYSTEMD" = false ] && { [ -d "/workspace" ] || [ -n "${RUNPOD_POD_ID:-}" ]; }; then
    IS_CONTAINER=true
    log_info "Container/RunPod environment detected (No Systemd)."
else
    log_info "Native VPS environment detected (Systemd available)."
fi

# ------------------------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------------------------
if [ "$IS_CONTAINER" = true ]; then
    INSTALL_DIR="/workspace/comfyui"
    VENV_DIR="${INSTALL_DIR}/venv"
    # Containers often run as root, so we don't need sudo usually, but check user
    if [ "$EUID" -eq 0 ]; then
        USE_SUDO=false
    else
        USE_SUDO=true
    fi
else
    INSTALL_DIR="/opt/ai/comfyui"
    VENV_DIR="${INSTALL_DIR}/venv"
    USE_SUDO=true
fi

REPO_URL="https://github.com/Comfy-Org/ComfyUI.git"
SERVICE_NAME="comfyui"

# Helper for sudo
run_priv() {
    if [ "$USE_SUDO" = true ]; then
        sudo "$@"
    else
        "$@"
    fi
}

log_info "═══════════════════════════════════════════"
log_info "  Installing ComfyUI"
if [ "$IS_CONTAINER" = true ]; then
    log_info "  Mode: RunPod (Persistent)"
else
    log_info "  Mode: Native (Systemd)"
fi
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

# Nginx check (Skip on RunPod)
if [ "$IS_CONTAINER" = false ]; then
    if ! command -v nginx &>/dev/null; then
        log_warn "Nginx not installed. Installing..."
        bash "${SCRIPT_DIR}/apps/infrastructure/nginx/install.sh"
    fi
else
    log_info "Skipping Nginx check on RunPod."
fi
log_success "Dependencies checked"
echo ""

# Create installation directory
log_step "Step 3: Setting up directory"
if [ ! -d "$INSTALL_DIR" ]; then
    run_priv mkdir -p "$INSTALL_DIR"
    if [ "$USE_SUDO" = true ]; then
        run_priv chown -R $USER:$USER "$INSTALL_DIR"
    fi
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
else
    log_info "Virtual environment already exists."
fi

# Activate and install comfy-cli
log_step "Step 5: Installing Comfy-CLI and ComfyUI"
source "${VENV_DIR}/bin/activate"
pip install --upgrade pip
log_info "Installing comfy-cli..."
pip install comfy-cli

# Install ComfyUI
# We use git clone from the official Comfy-Org repository to ensure we are using the canonical source.
# comfy-cli is used for management, but initial install is better controlled via git for repo accuracy.
log_info "Installing ComfyUI from official repository..."
COMFY_MAIN_DIR="${INSTALL_DIR}/ComfyUI"

if [ ! -d "${COMFY_MAIN_DIR}" ]; then
    log_info "Cloning ComfyUI from ${REPO_URL}..."
    git clone "$REPO_URL" "$COMFY_MAIN_DIR"
    
    cd "$COMFY_MAIN_DIR"
    log_info "Installing dependencies..."
    pip install -r requirements.txt
    
    # Optional: Install extra dependencies for common nodes if needed, or just let Manager handle it later.
    log_success "ComfyUI installed from official repo"
else
    log_info "ComfyUI directory already exists at ${COMFY_MAIN_DIR}"
    
    # Check if a valid install
    if [ -f "${COMFY_MAIN_DIR}/main.py" ]; then
        log_info "Valid installation found. Attempting update..."
        cd "${COMFY_MAIN_DIR}"
        
        # Check remote origin to ensure it matches desired REPO_URL
        CURRENT_REMOTE=$(git remote get-url origin || echo "")
        if [ "$CURRENT_REMOTE" != "$REPO_URL" ]; then
            log_warn "Current git remote ($CURRENT_REMOTE) does not match official ($REPO_URL)."
            log_warn "Updating remote to official..."
            git remote set-url origin "$REPO_URL"
        fi
        
        git pull || log_warn "Git pull failed, continuing..."
        
        log_info "Updating dependencies..."
        pip install -r requirements.txt
    else
        log_warn "Directory exists but main.py not found. Re-installing..."
        git clone "$REPO_URL" "$COMFY_MAIN_DIR"
        cd "$COMFY_MAIN_DIR"
        pip install -r requirements.txt
    fi
fi
echo ""

# Install ComfyUI Manager
log_step "Step 5b: Installing ComfyUI Manager"
MANAGER_DIR="${COMFY_MAIN_DIR}/custom_nodes/ComfyUI-Manager"
if [ ! -d "$MANAGER_DIR" ]; then
    log_info "Cloning ComfyUI Manager..."
    git clone https://github.com/ltdrdata/ComfyUI-Manager.git "$MANAGER_DIR"
    log_success "ComfyUI Manager installed"
else
    log_info "ComfyUI Manager already exists, updating..."
    cd "$MANAGER_DIR"
    git pull || log_warn "Failed to update ComfyUI Manager"
fi
echo ""

# ------------------------------------------------------------------------------
# SYSTEM SERVICE (Native Only)
# ------------------------------------------------------------------------------
if [ "$IS_CONTAINER" = false ]; then
    log_step "Step 6: Creating Systemd Service"
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    COMFY_CODE_DIR="${INSTALL_DIR}/ComfyUI"
    
    run_priv tee "$SERVICE_FILE" > /dev/null <<EOF
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

    run_priv systemctl daemon-reload
    run_priv systemctl enable "$SERVICE_NAME"
    run_priv systemctl restart "$SERVICE_NAME"

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
    
    run_priv tee "$NGINX_CONF" > /dev/null <<EOF
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
    
    run_priv ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/$APP_NAME.conf"
    
    if run_priv nginx -t; then
        run_priv systemctl reload nginx
        log_success "Nginx configured"
    else
        log_error "Nginx configuration failed"
    fi
else
    # RunPod Specific Helper Script
    log_step "Step 6: creating start script"
    START_SCRIPT="${INSTALL_DIR}/start.sh"
    cat > "$START_SCRIPT" <<EOF
#!/bin/bash
source "${VENV_DIR}/bin/activate"
cd "${INSTALL_DIR}/ComfyUI"
python main.py --listen 0.0.0.0 --port 8188 --use-pytorch-cross-attention --preview-method auto
EOF
    chmod +x "$START_SCRIPT"
    log_success "Created start script at ${START_SCRIPT}"
fi

echo ""
log_success "═══════════════════════════════════════════"
log_success "  ComfyUI Installation Complete!"
log_success "═══════════════════════════════════════════"
if [ "$IS_RUNPOD" = true ]; then
    echo "  Mode: RunPod"
    echo "  To start manually: ${INSTALL_DIR}/start.sh"
    echo "  Port: 8188 (Direct)"
else
    echo "  URL: http://$DOMAIN"
    echo "  Service: sudo systemctl status $SERVICE_NAME"
fi
echo "  Path: $INSTALL_DIR"
echo ""

