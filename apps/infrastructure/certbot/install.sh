#!/bin/bash

# ==============================================================================
# CERTBOT SSL CERTIFICATE MANAGEMENT (NATIVE)
# Let's Encrypt SSL certificates with automatic renewal via systemd timer
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"

APP_NAME="certbot"
CERT_DIR="/etc/letsencrypt"
WEBROOT_DIR="/var/www/html"

log_info "═══════════════════════════════════════════"
log_info "  Installing Certbot (Let's Encrypt)"
log_info "═══════════════════════════════════════════"
echo ""

# Detect OS
log_step "Step 1: Detecting operating system"
detect_os
log_success "OS detected: $OS_TYPE"
log_info "Package manager: $PACKAGE_MANAGER"
echo ""

# Check dependencies
log_step "Step 2: Checking dependencies"

# Check if Nginx is installed
NGINX_RUNNING=false
if command -v nginx &>/dev/null; then
    # Ensure Nginx is running
    ensure_service_running nginx "Nginx"
    NGINX_RUNNING=true
    log_success "✓ Nginx detected and running"
else
    log_warn "Nginx not detected"
    log_info "Certbot can still work in standalone mode"
    log_info "However, it's recommended to install Nginx first"
    
    if ! confirm_action "Continue without Nginx?"; then
        log_info "Installation cancelled"
        log_info "Install Nginx first: Infrastructure > Nginx"
        exit 0
    fi
fi
echo ""

# Install Certbot
log_step "Step 3: Installing Certbot"
pkg_update

if is_debian_based; then
    pkg_install certbot
    if [ "$NGINX_RUNNING" = true ]; then
        pkg_install python3-certbot-nginx
    fi
elif is_rhel_based; then
    pkg_install epel-release
    pkg_install certbot
    if [ "$NGINX_RUNNING" = true ]; then
        pkg_install python3-certbot-nginx
    fi
else
    log_error "Unsupported OS: $OS_ID"
    exit 1
fi

log_success "Certbot installed"
echo ""

# Setup directories
log_step "Step 4: Setting up directories"
run_sudo mkdir -p "$WEBROOT_DIR/.well-known/acme-challenge"
run_sudo chown -R www-data:www-data "$WEBROOT_DIR" 2>/dev/null || run_sudo chown -R nginx:nginx "$WEBROOT_DIR" 2>/dev/null || true
log_success "Directories configured"
echo ""

# Create helper script for certificate requests
log_step "Step 5: Creating helper scripts"

run_sudo tee /usr/local/bin/certbot-request > /dev/null <<'EOF'
#!/bin/bash
# Helper script to request SSL certificates

set -euo pipefail

if [ $# -eq 0 ]; then
    echo "Usage: sudo certbot-request domain.com [subdomain.domain.com ...]"
    echo ""
    echo "Examples:"
    echo "  sudo certbot-request example.com www.example.com"
    echo "  sudo certbot-request app.example.com"
    exit 1
fi

DOMAINS="$*"
DOMAIN_ARGS=""

for domain in $DOMAINS; do
    DOMAIN_ARGS="$DOMAIN_ARGS -d $domain"
done

echo "Requesting SSL certificate for: $DOMAINS"
echo ""

# Check if Nginx is running
if systemctl is-active --quiet nginx; then
    echo "Using Nginx plugin (webroot mode)..."
    certbot certonly \
        --nginx \
        $DOMAIN_ARGS \
        --non-interactive \
        --agree-tos \
        --email admin@$(echo $DOMAINS | awk '{print $1}') \
        --keep-until-expiring
else
    echo "Using standalone mode..."
    echo "WARNING: This will temporarily bind to port 80"
    certbot certonly \
        --standalone \
        $DOMAIN_ARGS \
        --non-interactive \
        --agree-tos \
        --email admin@$(echo $DOMAINS | awk '{print $1}') \
        --keep-until-expiring
fi

if [ $? -eq 0 ]; then
    echo ""
    echo "✓ Certificate obtained successfully!"
    echo ""
    echo "Certificate files:"
    echo "  Fullchain: /etc/letsencrypt/live/$(echo $DOMAINS | awk '{print $1}')/fullchain.pem"
    echo "  Privkey:   /etc/letsencrypt/live/$(echo $DOMAINS | awk '{print $1}')/privkey.pem"
    echo ""
    
    if systemctl is-active --quiet nginx; then
        echo "Reloading Nginx..."
        systemctl reload nginx
        echo "✓ Nginx reloaded"
    fi
else
    echo ""
    echo "✗ Certificate request failed"
    echo "Check the error messages above"
    exit 1
fi
EOF

run_sudo chmod +x /usr/local/bin/certbot-request

# Create renewal hook script
run_sudo mkdir -p /etc/letsencrypt/renewal-hooks/deploy
run_sudo tee /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh > /dev/null <<'EOF'
#!/bin/bash
# Reload Nginx after certificate renewal

if systemctl is-active --quiet nginx; then
    systemctl reload nginx
    echo "Nginx reloaded after certificate renewal"
fi
EOF

run_sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh

log_success "Helper scripts created"
echo ""

# Configure automatic renewal
log_step "Step 6: Configuring automatic renewal"

# Check if systemd timer exists (most modern systems)
if run_sudo systemctl is-enabled certbot.timer &>/dev/null 2>&1 || run_sudo systemctl status certbot.timer &>/dev/null 2>&1; then
    run_sudo systemctl enable certbot.timer
    run_sudo systemctl start certbot.timer
    log_success "Systemd timer configured for automatic renewal"
else
    # Fallback to cron
    CRON_CMD="0 3 * * * certbot renew --quiet --deploy-hook '/etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh'"
    (crontab -l 2>/dev/null | grep -v certbot; echo "$CRON_CMD") | run_sudo crontab -
    log_success "Cron job configured for automatic renewal"
fi
echo ""

# Test renewal (dry-run)
log_step "Step 7: Testing renewal configuration"
if run_sudo certbot renew --dry-run 2>&1 | grep -q "Congratulations"; then
    log_success "Renewal test passed"
else
    log_warn "Renewal test completed (no certificates to renew yet)"
fi
echo ""

# Display installation info
log_success "═══════════════════════════════════════════"
log_success "  Certbot Installation Complete!"
log_success "═══════════════════════════════════════════"
echo ""

log_info "Request your first certificate:"
cat <<'USAGE'
  # Single domain:
  sudo certbot-request example.com
  
  # Multiple domains (SAN certificate):
  sudo certbot-request example.com www.example.com
  
  # Subdomain:
  sudo certbot-request app.example.com
USAGE

echo ""
log_info "Manual certificate request (advanced):"
cat <<'MANUAL'
  # With Nginx plugin:
  sudo certbot certonly --nginx -d example.com -d www.example.com
  
  # Standalone (requires port 80 free):
  sudo certbot certonly --standalone -d example.com
  
  # Webroot mode:
  sudo certbot certonly --webroot -w /var/www/html -d example.com
MANUAL

echo ""
log_info "Configure Nginx for HTTPS:"
cat <<'NGINX_CONFIG'
  # Edit your site config: /etc/nginx/sites-available/mysite.conf
  
  server {
      listen 80;
      server_name example.com www.example.com;
      
      # Redirect HTTP to HTTPS
      return 301 https://$server_name$request_uri;
  }
  
  server {
      listen 443 ssl http2;
      server_name example.com www.example.com;
      
      # SSL certificates
      ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
      ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
      
      # SSL parameters
      include snippets/ssl-params.conf;
      
      location / {
          proxy_pass http://localhost:3000;
          include snippets/proxy-params.conf;
      }
  }
  
  # Test and reload:
  sudo nginx -t && sudo systemctl reload nginx
NGINX_CONFIG

echo ""
log_info "Useful commands:"
echo "  sudo certbot-request domain.com         # Request certificate"
echo "  sudo certbot certificates               # List certificates"
echo "  sudo certbot renew                      # Manual renewal"
echo "  sudo certbot renew --dry-run            # Test renewal"
echo "  sudo certbot delete --cert-name domain  # Delete certificate"
echo "  sudo systemctl status certbot.timer     # Check auto-renewal timer"
echo "  sudo journalctl -u certbot.timer        # View renewal logs"
echo ""

log_info "Certificate locations:"
echo "  Certificates: $CERT_DIR/live/"
echo "  Archive:      $CERT_DIR/archive/"
echo "  Renewal conf: $CERT_DIR/renewal/"
echo ""

log_warn "Important Notes:"
echo "  • Certificates auto-renew every 60 days via systemd timer"
echo "  • Rate limit: 5 certificates per domain per week"
echo "  • Test with --dry-run before real requests"
echo "  • Backup $CERT_DIR directory regularly"
echo "  • Domain must point to this server's IP"
echo "  • Port 80 must be accessible from internet"
echo ""

log_info "Troubleshooting:"
echo "  • DNS not propagated: wait 24-48 hours"
echo "  • Port 80 blocked: check firewall (ufw allow 80)"
echo "  • Domain not pointing here: check DNS A record"
echo "  • Nginx config error: sudo nginx -t"
echo ""

