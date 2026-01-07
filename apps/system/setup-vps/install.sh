#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/docker.sh"

APP_NAME="setup-vps"

log_info "VPS Initial Setup..."
log_info "This is a workflow, not an app installation."

if [ -f "$SCRIPT_DIR/workflows/vps-initial-setup.sh" ]; then
    log_info "Running VPS initial setup workflow..."
    bash "$SCRIPT_DIR/workflows/vps-initial-setup.sh"
else
    log_warn "VPS initial setup workflow not yet available"
    log_info ""
    log_info "For now, install components individually:"
    log_info "  1. Docker Engine (required for most apps)"
    log_info "  2. Nginx (for reverse proxy)"
    log_info "  3. Certbot (for SSL certificates)"
    log_info "  4. Fail2ban (for security)"
    log_info ""
    log_info "Use the orchestrator menu to install these components."
    exit 0
fi
