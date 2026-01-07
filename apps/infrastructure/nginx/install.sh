#!/bin/bash

# ==============================================================================
# NGINX REVERSE PROXY INSTALLATION (NATIVE)
# Installs Nginx directly on host system for maximum performance
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"

APP_NAME="nginx"
CONF_DIR="/etc/nginx"
HTML_DIR="/var/www/html"
LOG_DIR="/var/log/nginx"

log_info "═══════════════════════════════════════════"
log_info "  Installing Nginx Reverse Proxy (Native)"
log_info "═══════════════════════════════════════════"
echo ""

# Detect OS
log_step "Step 1: Detecting operating system"
detect_os
log_success "OS detected: $OS_TYPE"
log_info "Package manager: $PACKAGE_MANAGER"
echo ""

# Check if already installed
# Check if already installed
if systemctl is-active --quiet nginx 2>/dev/null; then
    log_warn "Nginx is already running"
    if confirm_action "Reinstall/Reconfigure? (This will overwrite configs!)"; then
        log_info "Proceeding with reconfiguration..."
    else
        log_info "Installation cancelled"
        exit 0
    fi
elif command -v nginx &>/dev/null; then
    log_warn "Nginx is installed but NOT running"
    
    if confirm_action "Start Nginx service instead of reinstalling?"; then
        log_info "Starting Nginx..."
        run_sudo systemctl start nginx
        if systemctl is-active --quiet nginx; then
            log_success "Nginx started successfully"
            exit 0
        else
            log_error "Failed to start Nginx. Check logs."
            if confirm_action "Proceed with full reinstall (destroys existing config)?"; then
                log_info "Proceeding with reinstall..."
            else
                exit 1
            fi
        fi
    else
        log_info "Proceeding with full reinstall..."
    fi
fi
echo ""

# Install Nginx
log_step "Step 2: Installing Nginx"
pkg_update
pkg_install nginx
log_success "Nginx installed"
echo ""

# Setup directories
log_step "Step 3: Setting up directories"
run_sudo mkdir -p "$HTML_DIR"
run_sudo mkdir -p "$CONF_DIR/sites-available"
run_sudo mkdir -p "$CONF_DIR/sites-enabled"
run_sudo mkdir -p "$CONF_DIR/ssl"
run_sudo mkdir -p "$CONF_DIR/snippets"
log_success "Directories created"
echo ""

# Create security configuration
log_step "Step 4: Creating security configuration"
run_sudo tee "$CONF_DIR/snippets/security.conf" > /dev/null <<'EOF'
# Security headers
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "no-referrer-when-downgrade" always;

# Hide Nginx version
server_tokens off;

# File upload limits
client_max_body_size 100M;
client_body_buffer_size 128k;
EOF

# Create SSL configuration
run_sudo tee "$CONF_DIR/snippets/ssl-params.conf" > /dev/null <<'EOF'
# SSL Configuration
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
ssl_session_timeout 10m;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;

# OCSP stapling
ssl_stapling on;
ssl_stapling_verify on;
resolver 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout 5s;
EOF

# Create proxy configuration
run_sudo tee "$CONF_DIR/snippets/proxy-params.conf" > /dev/null <<'EOF'
# Proxy headers
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Port $server_port;

# Proxy timeouts
proxy_connect_timeout 60s;
proxy_send_timeout 60s;
proxy_read_timeout 60s;

# Proxy buffering
proxy_buffering on;
proxy_buffer_size 4k;
proxy_buffers 8 4k;
proxy_busy_buffers_size 8k;
EOF

log_success "Security configurations created"
echo ""

# Update main nginx.conf
log_step "Step 5: Configuring main nginx.conf"
run_sudo tee "$CONF_DIR/nginx.conf" > /dev/null <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 2048;
    multi_accept on;
    use epoll;
}

http {
    # Basic Settings
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_names_hash_bucket_size 64;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # SSL Settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    # Logging Settings
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    # Gzip Settings
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript 
               application/json application/javascript application/xml+rss 
               application/rss+xml font/truetype font/opentype 
               application/vnd.ms-fontobject image/svg+xml;

    # Virtual Host Configs
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

log_success "Main configuration updated"
echo ""

# Create default site
log_step "Step 6: Creating default site"
run_sudo tee "$CONF_DIR/sites-available/default" > /dev/null <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /var/www/html;
    index index.html index.htm index.nginx-debian.html;

    # Security headers
    include snippets/security.conf;

    location / {
        try_files $uri $uri/ =404;
    }

    # Health check endpoint
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }

    # Deny access to hidden files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF

# Enable default site
run_sudo ln -sf "$CONF_DIR/sites-available/default" "$CONF_DIR/sites-enabled/default"

# Create default index page
run_sudo tee "$HTML_DIR/index.html" > /dev/null <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome to Nginx</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            color: #333;
        }
        .container {
            background: white;
            padding: 3rem;
            border-radius: 10px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            text-align: center;
            max-width: 600px;
        }
        h1 {
            color: #009639;
            font-size: 2.5rem;
            margin-bottom: 1rem;
        }
        p {
            color: #666;
            font-size: 1.1rem;
            line-height: 1.6;
        }
        .status {
            margin-top: 2rem;
            padding: 1rem;
            background: #f0f9ff;
            border-left: 4px solid #009639;
            border-radius: 4px;
        }
        .status strong { color: #009639; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 Nginx is Running!</h1>
        <p>Your web server is successfully configured and ready to serve content.</p>
        <div class="status">
            <strong>✓ Status:</strong> Operational<br>
            <strong>✓ HTTP:</strong> Enabled (Port 80)<br>
            <strong>✓ Configuration:</strong> Native Installation
        </div>
    </div>
</body>
</html>
EOF

# Set ownership based on OS
if is_debian_based; then
    run_sudo chown -R www-data:www-data "$HTML_DIR"
elif is_rhel_based; then
    run_sudo chown -R nginx:nginx "$HTML_DIR"
else
    # Fallback: try www-data first, then nginx
    run_sudo chown -R www-data:www-data "$HTML_DIR" 2>/dev/null || run_sudo chown -R nginx:nginx "$HTML_DIR" 2>/dev/null || true
fi
log_success "Default site configured"
echo ""

# Test configuration
log_step "Step 7: Testing Nginx configuration"
if run_sudo nginx -t; then
    log_success "Configuration test passed"
else
    log_error "Configuration test failed"
    exit 1
fi
echo ""

# Enable and start Nginx
log_step "Step 8: Starting Nginx service"
run_sudo systemctl enable nginx
run_sudo systemctl restart nginx

if systemctl is-active --quiet nginx; then
    log_success "Nginx is running"
else
    log_error "Failed to start Nginx"
    exit 1
fi
echo ""

# Configure firewall
log_step "Step 9: Configuring Firewall"
if command -v ufw &>/dev/null && run_sudo ufw status | grep -q "Status: active"; then
    log_info "Opening HTTP (80) and HTTPS (443) ports in UFW..."
    run_sudo ufw allow 80/tcp comment "HTTP"
    run_sudo ufw allow 443/tcp comment "HTTPS"
    log_success "Firewall rules added for HTTP/HTTPS"
elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
    log_info "Opening HTTP and HTTPS ports in firewalld..."
    run_sudo firewall-cmd --permanent --add-service=http
    run_sudo firewall-cmd --permanent --add-service=https
    run_sudo firewall-cmd --reload
    log_success "Firewall rules added for HTTP/HTTPS"
else
    log_warn "No active firewall detected (ufw/firewalld)"
    log_info "If using a firewall, manually allow ports 80 and 443"
fi
echo ""

# Display installation info
log_success "═══════════════════════════════════════════"
log_success "  Nginx Installation Complete!"
log_success "═══════════════════════════════════════════"
echo ""

SERVER_IP=$(hostname -I | awk '{print $1}')

log_info "Access Information:"
echo "  HTTP:  http://${SERVER_IP}"
echo "  HTTPS: Configure SSL first (use Certbot)"
echo ""

log_info "Configuration Files:"
echo "  Main Config:     $CONF_DIR/nginx.conf"
echo "  Sites Available: $CONF_DIR/sites-available/"
echo "  Sites Enabled:   $CONF_DIR/sites-enabled/"
echo "  Snippets:        $CONF_DIR/snippets/"
echo "  HTML Root:       $HTML_DIR"
echo "  Logs:            $LOG_DIR"
echo ""

log_info "Create a new site:"
cat <<'EXAMPLE'
  # Create config file:
  sudo nano /etc/nginx/sites-available/myapp.conf
  
  # Example reverse proxy:
  server {
      listen 80;
      server_name myapp.example.com;
      
      include snippets/security.conf;
      
      location / {
          proxy_pass http://localhost:3000;
          include snippets/proxy-params.conf;
      }
  }
  
  # Enable site:
  sudo ln -s /etc/nginx/sites-available/myapp.conf /etc/nginx/sites-enabled/
  sudo nginx -t && sudo systemctl reload nginx
EXAMPLE

echo ""
log_info "Useful commands:"
echo "  sudo systemctl status nginx     # Check status"
echo "  sudo systemctl reload nginx     # Reload config"
echo "  sudo systemctl restart nginx    # Restart service"
echo "  sudo nginx -t                   # Test configuration"
echo "  sudo tail -f /var/log/nginx/access.log  # View access logs"
echo "  sudo tail -f /var/log/nginx/error.log   # View error logs"
echo ""

log_warn "Security Note:"
echo "  • Configure SSL certificates with Certbot"
echo "  • Update firewall: sudo ufw allow 'Nginx Full'"
echo "  • Review security settings in snippets/security.conf"
echo ""

# Setup dashboard
log_step "Step 9: Setting up health dashboard"
if [ -f "${SCRIPT_DIR}/tools/setup-dashboard.sh" ]; then
    run_sudo bash "${SCRIPT_DIR}/tools/setup-dashboard.sh"
    log_success "Health dashboard configured"
else
    log_warn "Dashboard setup script not found at ${SCRIPT_DIR}/tools/setup-dashboard.sh"
fi
echo ""

