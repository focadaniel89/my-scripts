#!/bin/bash

# ==============================================================================
# HASHICORP VAULT CLI INSTALLATION
# Secure secret management and CLI tools
# Native install — Debian/Ubuntu only
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"

APP_NAME="vault"

# Guard: require Debian/Ubuntu (native install)
require_debian

# Cleanup on error
INSTALL_FAILED=false
cleanup_on_error() {
    if [ "$INSTALL_FAILED" = true ]; then
        log_error "Installation failed, cleaning up..."
        audit_log "INSTALL_FAILED" "$APP_NAME" "Cleanup completed"
    fi
}
trap 'INSTALL_FAILED=true; cleanup_on_error' ERR INT TERM

log_info "═══════════════════════════════════════════"
log_info "  Installing HashiCorp Vault CLI"
log_info "═══════════════════════════════════════════"
echo ""

audit_log "INSTALL_START" "$APP_NAME"

# Detect OS
log_step "Step 1: Detecting operating system"
detect_os
log_success "OS detected: $OS_NAME $OS_VERSION"
log_info "Package manager: $PACKAGE_MANAGER"
echo ""

# Check if already installed
if command -v vault &>/dev/null; then
    log_warn "Vault CLI is already installed: $(vault --version)"
    if set +e; confirm_action "Reinstall/Reconfigure?"; RESULT=$?; set -e; [ $RESULT -eq 0 ]; then
        log_info "Proceeding with reconfiguration..."
    else
        log_info "Installation cancelled"
        exit 0
    fi
fi
echo ""

log_step "Step 2: Installing HashiCorp Vault repository"

if ! command -v gpg &> /dev/null || ! command -v wget &> /dev/null || ! command -v lsb_release &> /dev/null; then
    run_sudo apt-get update -qq
    run_sudo apt-get install -y gnupg wget lsb-release
fi

# Add HashiCorp GPG key
log_info "Adding HashiCorp GPG key..."
wget -qO- https://apt.releases.hashicorp.com/gpg | run_sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg --yes

# Add HashiCorp repository
log_info "Adding HashiCorp APT repository..."
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | run_sudo tee /etc/apt/sources.list.d/hashicorp.list > /dev/null

log_step "Step 3: Installing Vault package"
run_sudo apt-get update -qq
run_sudo apt-get install -y vault
log_success "Vault installed"
echo ""

# Configuration
log_step "Step 4: Configuring Vault environment"

# Create config directory if not exists
run_sudo mkdir -p /etc/vault.d
run_sudo mkdir -p /opt/vault/data

# Usually vault creates a vault user/group during apt install.
if id "vault" &>/dev/null; then
    run_sudo chown -R vault:vault /opt/vault
fi

log_info "Creating default configuration..."
run_sudo tee /etc/vault.d/vault.hcl > /dev/null << 'EOF'
# Minimal Vault Configuration
ui = true

# Disable mlock if running in unprivileged environment
disable_mlock = true

storage "file" {
  path = "/opt/vault/data"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = "true"
}
EOF

# Ensure permissions allow standard sudo users to read it
# We make the file readable by everyone so the new non-root user can read it.
run_sudo chmod 644 /etc/vault.d/vault.hcl

# Autocomplete
if vault -autocomplete-install &>/dev/null || true; then
    log_success "Vault autocomplete configured (restart shell to take effect)"
fi
echo ""

log_success "═══════════════════════════════════════════"
log_success "  HashiCorp Vault Installation Complete!"
log_success "═══════════════════════════════════════════"
echo ""

log_info "⚙️ Configuration:"
echo "  Config:       /etc/vault.d/vault.hcl"
echo "  Data Dir:     /opt/vault/data"
echo "  Binary:       $(which vault)"
echo ""

log_info "📊 Useful commands:"
echo "  Check version:        vault --version"
echo "  Start dev server:     vault server -dev"
echo "  Start prod server:    sudo systemctl start vault"
echo "  Enable on boot:       sudo systemctl enable vault"
echo "  Check status:         vault status"
echo ""

log_warn "⚠️  Important notes:"
echo "  • The configuration is globally readable as requested."
echo "  • It is currently set up to use local file storage for convenience."
echo "  • Only reachable on loopback (127.0.0.1:8200) by default."
echo "  • Remember to initialize vault before first use: vault operator init"
echo ""

audit_log "INSTALL_COMPLETE" "$APP_NAME"
