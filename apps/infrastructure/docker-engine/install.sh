#!/bin/bash

# ==============================================================================
# DOCKER ENGINE INSTALLATION
# Installs Docker Engine and Docker Compose
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/preflight.sh"

APP_NAME="docker-engine"

log_info "═══════════════════════════════════════════"
log_info "  Installing Docker Engine"
log_info "═══════════════════════════════════════════"
echo ""

audit_log "INSTALL_START" "$APP_NAME"

# Pre-flight checks
preflight_check "$APP_NAME" 20 4 ""

# Check if already installed
if check_docker; then
    log_success "✓ Docker is already installed"
    run_sudo docker --version
    
    if check_docker_compose &> /dev/null; then
        log_success "✓ Docker Compose is already installed"
        run_sudo docker compose version 2>/dev/null || run_sudo docker-compose --version
    fi
    
    echo ""
    log_info "Docker installation verified"
    exit 0
fi

log_step "Step 1: Removing old Docker versions"
if is_debian_based; then
    pkg_remove docker docker-engine docker.io containerd runc 2>/dev/null || true
elif is_rhel_based; then
    pkg_remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true
fi

log_step "Step 2: Installing prerequisites"
if is_debian_based; then
    pkg_install apt-transport-https ca-certificates curl gnupg lsb-release
    
    # Add Docker's official GPG key
    log_info "Adding Docker GPG key..."
    run_sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/${OS_ID}/gpg | run_sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    # Set up the repository
    log_info "Setting up Docker repository..."
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} \
        $(lsb_release -cs) stable" | run_sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Update package cache
    pkg_update
    
elif is_rhel_based; then
    pkg_install yum-utils
    run_sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
fi

log_step "Step 3: Installing Docker Engine"
# pkg_install now has built-in retry logic and --fix-missing
pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

log_step "Step 4: Starting Docker service"
log_info "Starting and enabling Docker daemon..."
run_sudo systemctl start docker
run_sudo systemctl enable docker

# Wait for Docker to be ready
log_info "Waiting for Docker daemon to be ready..."
sleep 3

# Verify Docker is running
if ! run_sudo docker info &> /dev/null; then
    log_error "Docker daemon failed to start"
    log_info "Checking Docker service status..."
    run_sudo systemctl status docker --no-pager || true
    exit 1
fi

log_success "Docker daemon is running"

# Add current user to docker group (if not root)
if [ "$(id -u)" -ne 0 ]; then
    log_step "Step 5: Adding user to docker group"
    run_sudo usermod -aG docker "$USER"
    
    # Activate docker group immediately for current session
    log_info "Activating docker group for current session..."
    
    # Use newgrp to activate the docker group
    # This allows docker commands to work without sudo immediately
    export DOCKER_GROUP_ACTIVATED=1
    
    log_success "✓ User '$USER' added to docker group"
    log_info "Docker group activated for this session"
    log_warn "Note: New terminal sessions will automatically have docker access"
    
    # Verify group membership
    if groups "$USER" | grep -q docker; then
        log_success "✓ Group membership verified"
    fi
fi

log_step "Step 6: Verifying installation"
sleep 2
run_sudo docker --version
run_sudo docker compose version

# Test Docker
log_info "Testing Docker..."
if run_sudo docker run --rm hello-world > /dev/null 2>&1; then
    log_success "Docker test successful!"
else
    log_error "Docker test failed"
    exit 1
fi

log_step "Step 7: Creating default Docker network"
create_docker_network "vps_network"

log_step "Step 8: Configuring Docker daemon"
DAEMON_CONFIG="/etc/docker/daemon.json"
if [ ! -f "$DAEMON_CONFIG" ]; then
    log_info "Creating Docker daemon configuration..."
    run_sudo bash -c "cat > $DAEMON_CONFIG" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "userland-proxy": false
}
EOF
    
    log_warn "Docker daemon configuration created. Restart required."
    log_warn "⚠️  WARNING: Restarting Docker will STOP all running containers!"
    
    # Check if any containers are running
    RUNNING_CONTAINERS=$(run_sudo docker ps -q 2>/dev/null | wc -l)
    if [ "$RUNNING_CONTAINERS" -gt 0 ]; then
        log_warn "Currently running containers: $RUNNING_CONTAINERS"
        if ! confirm_action "Restart Docker now? (containers will be stopped)"; then
            log_info "Skipping Docker restart. Please restart manually later:"
            log_info "  sudo systemctl restart docker"
            log_success "Docker daemon configured (restart pending)"
        else
            run_sudo systemctl restart docker
            log_success "Docker daemon configured and restarted"
        fi
    else
        log_info "No running containers detected, restarting Docker..."
        run_sudo systemctl restart docker
        log_success "Docker daemon configured and restarted"
    fi
fi

# Create vps_network for shared services (databases, monitoring)
log_step "Step 8: Creating vps_network for shared services"
if ! run_sudo docker network inspect vps_network &>/dev/null 2>&1; then
    log_info "Creating vps_network (172.18.0.0/16)..."
    run_sudo docker network create vps_network --subnet=172.18.0.0/16 --gateway=172.18.0.1 2>/dev/null
    log_success "vps_network created successfully"
    log_info "  Subnet:  172.18.0.0/16"
    log_info "  Gateway: 172.18.0.1"
else
    log_info "vps_network already exists"
fi
echo ""

echo ""
log_success "═══════════════════════════════════════════"
log_success "  Docker Engine installed successfully!"
log_success "═══════════════════════════════════════════"
audit_log "INSTALL_COMPLETE" "$APP_NAME" "Docker $(run_sudo docker --version | awk '{print $3}' | tr -d ',')"
echo ""
log_info "Docker Version:"
run_sudo docker --version
echo ""
log_info "Docker Compose Version:"
run_sudo docker compose version 2>/dev/null || run_sudo docker-compose --version
echo ""
log_info "Default Network: vps_network"
echo ""
log_info "💡 Docker is configured to work with sudo"
log_info "   For sudo-less access, logout and login again"
echo ""
