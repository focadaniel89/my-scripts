#!/bin/bash
# Generate self-signed SSL certificate for domain
# Usage: ./generate-self-signed-cert.sh <domain>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"

# Check arguments
if [ $# -lt 1 ]; then
    log_error "Usage: $0 <domain>"
    exit 1
fi

DOMAIN="$1"
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
KEY_FILE="/etc/ssl/private/${DOMAIN}.key"
CERT_FILE="/etc/ssl/certs/${DOMAIN}.crt"

log_info "═══════════════════════════════════════════"
log_info "  Generating Self-Signed Certificate"
log_info "═══════════════════════════════════════════"
echo ""
log_info "Domain: $DOMAIN"
log_info "Valid for: 10 years"
echo ""

# Create directories
run_sudo mkdir -p /etc/ssl/private
run_sudo mkdir -p /etc/ssl/certs
run_sudo mkdir -p "$CERT_DIR"

# Generate self-signed certificate
log_step "Generating certificate..."
run_sudo openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -subj "/CN=${DOMAIN}/O=Self-Signed/C=US"

if [ $? -eq 0 ]; then
    log_success "Certificate generated"
else
    log_error "Failed to generate certificate"
    exit 1
fi

# Set permissions
run_sudo chmod 600 "$KEY_FILE"
run_sudo chmod 644 "$CERT_FILE"

# Create symlinks for compatibility with Let's Encrypt structure
log_step "Creating symlinks..."
run_sudo ln -sf "$CERT_FILE" "${CERT_DIR}/fullchain.pem"
run_sudo ln -sf "$KEY_FILE" "${CERT_DIR}/privkey.pem"
log_success "Symlinks created"

echo ""
log_success "Self-signed certificate created successfully!"
echo ""
echo "Certificate files:"
echo "  Key:  $KEY_FILE"
echo "  Cert: $CERT_FILE"
echo ""
echo "Symlinks for compatibility:"
echo "  ${CERT_DIR}/fullchain.pem -> $CERT_FILE"
echo "  ${CERT_DIR}/privkey.pem -> $KEY_FILE"
echo ""
log_warn "IMPORTANT: Configure Cloudflare SSL mode to 'Full' (not 'Full Strict')"
log_warn "Cloudflare Dashboard → SSL/TLS → Overview → Full"
echo ""
