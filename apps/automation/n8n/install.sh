#!/bin/bash

# ==============================================================================
# N8N WORKFLOW AUTOMATION PLATFORM
# Self-hosted workflow automation with 300+ integrations
# Includes: Domain configuration, SSL certificate, PostgreSQL database
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/preflight.sh"

APP_NAME="n8n"
CONTAINER_NAME="n8n"
DATA_DIR="/opt/automation/n8n"
NETWORK="n8n_network"

# Cleanup on error
INSTALL_FAILED=false
COMPOSE_FILE_CREATED=false
cleanup_on_error() {
    if [ "$INSTALL_FAILED" = true ]; then
        log_error "Installation failed, cleaning up..."
        
        # Stop and remove container if running
        if run_sudo docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$" 2>/dev/null; then
            log_info "Removing failed container: $CONTAINER_NAME"
            run_sudo docker compose -f "${DATA_DIR}/docker-compose.yml" down 2>/dev/null || true
            run_sudo docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
        fi
        
        # Remove docker-compose.yml if it was created during this failed installation
        if [ "$COMPOSE_FILE_CREATED" = true ] && [ -f "${DATA_DIR}/docker-compose.yml" ]; then
            log_info "Removing incomplete docker-compose.yml"
            run_sudo rm -f "${DATA_DIR}/docker-compose.yml" 2>/dev/null || true
        fi
        
        audit_log "INSTALL_FAILED" "$APP_NAME" "Cleanup completed"
        log_error "Installation aborted. You can retry by running this script again."
    fi
}
trap 'INSTALL_FAILED=true; cleanup_on_error' ERR

log_info "═══════════════════════════════════════════"
log_info "  Installing n8n Workflow Automation"
log_info "═══════════════════════════════════════════"
echo ""

audit_log "INSTALL_START" "$APP_NAME"

# Pre-flight checks
preflight_check "$APP_NAME" 10 2 "5678"

# Check dependencies
log_step "Step 1: Checking dependencies"

# Docker check
if ! check_docker; then
    log_error "Docker is not installed"
    log_info "Please run orchestrator or install Docker first"
    exit 1
fi
log_success "✓ Docker is available"

# PostgreSQL check (REQUIRED)
POSTGRES_AVAILABLE=false
if run_sudo docker ps --format '{{.Names}}' | grep -q "^postgres$"; then
    POSTGRES_AVAILABLE=true
    log_success "✓ PostgreSQL detected"
else
    log_error "PostgreSQL is not installed"
    log_info "Please run orchestrator or install PostgreSQL first"
    exit 1
fi

# Nginx check (REQUIRED for SSL)
if ! command -v nginx &>/dev/null; then
    log_error "Nginx is not installed"
    log_info "Please run orchestrator or install Nginx first"
    exit 1
fi

# Ensure Nginx is running
ensure_service_running nginx "Nginx"
log_success "✓ Nginx is available"

# Redis check (REQUIRED for queue mode)
REDIS_PASSWORD=""
if run_sudo docker ps --format '{{.Names}}' | grep -q "^redis$"; then
    log_success "✓ Redis container detected"
    
    # Load Redis credentials for n8n connection (from redis-docker installation)
    if has_credentials "redis-docker"; then
        REDIS_PASSWORD=$(get_secret "redis-docker" "REDIS_PASSWORD")
        log_success "✓ Redis credentials loaded from redis-docker"
    else
        log_error "Redis credentials not found!"
        log_info "Please ensure Redis container was installed with credentials"
        log_info "Expected: ~/.vps-secrets/.env_redis-docker"
        exit 1
    fi
else
    log_error "Redis container is not running"
    log_info "Please install Redis first: ./apps/databases/redis-docker/install.sh"
    exit 1
fi

# SSL certificate type will be chosen by user during installation
echo ""

# Check for existing installation
if run_sudo docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_success "✓ n8n is already installed"
    if confirm_action "Reinstall?"; then
        log_info "Removing existing installation..."
        run_sudo docker stop "$CONTAINER_NAME" 2>/dev/null || true
        run_sudo docker rm "$CONTAINER_NAME" 2>/dev/null || true
    else
        log_info "Installation cancelled"
        exit 0
    fi
fi
echo ""

# Domain and email configuration
log_step "Step 2: Domain and SSL configuration"
echo ""
log_info "n8n requires a domain name for SSL certificate"
log_info "Example: domain.com or n8n.domain.com"
echo ""

# Domain prompt
while true; do
    read -p "Enter your domain name: " N8N_DOMAIN
    N8N_DOMAIN=$(echo "$N8N_DOMAIN" | xargs) # trim whitespace
    
    if [ -z "$N8N_DOMAIN" ]; then
        log_error "Domain cannot be empty"
        continue
    fi
    
    # Basic domain validation
    if [[ ! "$N8N_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        log_error "Invalid domain format"
        continue
    fi
    
    log_success "Domain: $N8N_DOMAIN"
    break
done
echo ""

# Email prompt
log_info "SSL certificate requires an email address for notifications"
log_info "Example: admin@domain.com"
echo ""

while true; do
    read -p "Enter your email address: " N8N_EMAIL
    N8N_EMAIL=$(echo "$N8N_EMAIL" | xargs) # trim whitespace
    
    if [ -z "$N8N_EMAIL" ]; then
        log_error "Email cannot be empty"
        continue
    fi
    
    # Basic email validation
    if [[ ! "$N8N_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_error "Invalid email format"
        continue
    fi
    
    log_success "Email: $N8N_EMAIL"
    break
done

# Save domain and email
save_secret "$APP_NAME" "N8N_DOMAIN" "$N8N_DOMAIN"
save_secret "$APP_NAME" "N8N_EMAIL" "$N8N_EMAIL"
echo ""

# Generate encryption key
log_step "Step 3: Generating encryption key"

# Check if encryption key exists
N8N_ENCRYPTION_KEY=$(get_secret "$APP_NAME" "N8N_ENCRYPTION_KEY" 2>/dev/null || echo "")

if [ -z "$N8N_ENCRYPTION_KEY" ]; then
    log_info "Generating encryption key for secure data storage..."
    N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
    save_secret "$APP_NAME" "N8N_ENCRYPTION_KEY" "$N8N_ENCRYPTION_KEY"
    log_success "Encryption key generated"
else
    log_info "Using existing encryption key"
fi

log_info "User account will be created on first web access"
echo ""

# Set execution mode (regular mode - works reliably without Redis connection issues)
EXECUTION_MODE="queue"
log_info "Using regular execution mode (workflows run in main process)"
echo ""

# Create PostgreSQL database and user for n8n
log_step "Step 5: Creating PostgreSQL database and user"

# Load PostgreSQL superuser credentials (for authentication to CREATE resources)
log_info "Loading PostgreSQL superuser credentials..."
POSTGRES_USER=$(get_secret "postgres" "POSTGRES_USER")
POSTGRES_PASSWORD=$(get_secret "postgres" "DB_PASSWORD")

if [ -z "$POSTGRES_USER" ] || [ -z "$POSTGRES_PASSWORD" ]; then
    log_error "PostgreSQL credentials not found in ~/.vps-secrets/.env_postgres"
    log_info "Please ensure PostgreSQL is installed first"
    exit 1
fi

# Generate n8n specific credentials with random suffix
N8N_DB_NAME="n8n_$(generate_secure_password 4 'alphanumeric' | tr '[:upper:]' '[:lower:]')"
N8N_DB_USER="n8n_$(generate_secure_password 4 'alphanumeric' | tr '[:upper:]' '[:lower:]')"
N8N_DB_PASSWORD=$(generate_secure_password 32 "alphanumeric")

# Validate n8n database credentials before creation
if [ -z "$N8N_DB_NAME" ] || [ -z "$N8N_DB_USER" ] || [ -z "$N8N_DB_PASSWORD" ]; then
    log_error "Failed to generate n8n database credentials!"
    log_error "N8N_DB_NAME: ${N8N_DB_NAME:+SET} ${N8N_DB_NAME:-EMPTY}"
    log_error "N8N_DB_USER: ${N8N_DB_USER:+SET} ${N8N_DB_USER:-EMPTY}"
    log_error "N8N_DB_PASSWORD: ${N8N_DB_PASSWORD:+SET} ${N8N_DB_PASSWORD:-EMPTY}"
    exit 1
fi

log_info "Creating database: $N8N_DB_NAME"
log_info "Creating user: $N8N_DB_USER"
log_info "Authenticating with PostgreSQL superuser: $POSTGRES_USER"

# Create database (authenticate with postgres superuser)
run_sudo docker exec postgres psql -U "$POSTGRES_USER" -tc "SELECT 1 FROM pg_database WHERE datname = '$N8N_DB_NAME'" | grep -q 1 || \
    run_sudo docker exec postgres psql -U "$POSTGRES_USER" -c "CREATE DATABASE $N8N_DB_NAME;"

if [ $? -ne 0 ]; then
    log_error "Failed to create database: $N8N_DB_NAME"
    exit 1
fi

# Create n8n user (authenticate with postgres superuser)
run_sudo docker exec postgres psql -U "$POSTGRES_USER" -tc "SELECT 1 FROM pg_roles WHERE rolname = '$N8N_DB_USER'" | grep -q 1 || \
    run_sudo docker exec postgres psql -U "$POSTGRES_USER" -c "CREATE USER $N8N_DB_USER WITH ENCRYPTED PASSWORD '$N8N_DB_PASSWORD';"

if [ $? -ne 0 ]; then
    log_error "Failed to create user: $N8N_DB_USER"
    # Cleanup: drop database if user creation failed
    run_sudo docker exec postgres psql -U "$POSTGRES_USER" -c "DROP DATABASE IF EXISTS $N8N_DB_NAME;" 2>/dev/null || true
    exit 1
fi

# Grant privileges (authenticate with postgres superuser)
run_sudo docker exec postgres psql -U "$POSTGRES_USER" -c "GRANT ALL PRIVILEGES ON DATABASE $N8N_DB_NAME TO $N8N_DB_USER;"
run_sudo docker exec postgres psql -U "$POSTGRES_USER" -d "$N8N_DB_NAME" -c "GRANT ALL ON SCHEMA public TO $N8N_DB_USER;"

if [ $? -ne 0 ]; then
    log_error "Failed to grant privileges to user: $N8N_DB_USER"
    # Cleanup: drop user and database
    run_sudo docker exec postgres psql -U "$POSTGRES_USER" -c "DROP USER IF EXISTS $N8N_DB_USER;" 2>/dev/null || true
    run_sudo docker exec postgres psql -U "$POSTGRES_USER" -c "DROP DATABASE IF EXISTS $N8N_DB_NAME;" 2>/dev/null || true
    exit 1
fi

log_success "Database created successfully: $N8N_DB_NAME"
log_success "User created successfully: $N8N_DB_USER"
log_success "Privileges granted"

# Save n8n database credentials AFTER successful creation
save_secret "$APP_NAME" "DB_NAME" "$N8N_DB_NAME"
save_secret "$APP_NAME" "DB_USER" "$N8N_DB_USER"
save_secret "$APP_NAME" "DB_PASSWORD" "$N8N_DB_PASSWORD"

audit_log "CREATE_DATABASE" "$APP_NAME" "DB: $N8N_DB_NAME, User: $N8N_DB_USER"

log_success "Credentials saved securely"
log_success "N8N will connect as: $N8N_DB_USER@postgres/$N8N_DB_NAME"
echo ""

# Setup directories
log_step "Step 5: Setting up directories"
create_app_directory "$DATA_DIR"
create_app_directory "$DATA_DIR/.n8n"

# Fix ownership for n8n container (runs as user node with UID 1000)
run_sudo chown -R 1000:1000 "$DATA_DIR/.n8n"

log_success "n8n directories created"
echo ""

# Create Docker network
log_step "Step 6: Creating n8n network"
log_info "Creating n8n_network for n8n stack isolation..."
N8N_NETWORK_CREATED=false
if ! run_sudo docker network inspect n8n_network &>/dev/null 2>&1; then
    run_sudo docker network create n8n_network --subnet=172.19.0.0/16 --gateway=172.19.0.1 2>/dev/null
    log_success "n8n_network created (172.19.0.0/16)"
    N8N_NETWORK_CREATED=true
else
    log_info "n8n_network already exists"
fi

# Verify vps_network exists (for postgres access)
if ! run_sudo docker network inspect vps_network &>/dev/null 2>&1; then
    log_error "vps_network does not exist!"
    log_error "Please install docker-engine first: ./apps/infrastructure/docker-engine/install.sh"
    exit 1
fi
log_success "vps_network found"

# Set Redis host (container name for Docker DNS resolution)
REDIS_HOST="redis"
log_info "Redis connection: redis://redis:6379 (via vps_network)"
log_success "✓ Redis host configured"
echo ""

# Final validation of ALL critical n8n environment variables
log_info "Validating all n8n environment variables..."
MISSING_VARS=()
[ -z "$N8N_ENCRYPTION_KEY" ] && MISSING_VARS+=("N8N_ENCRYPTION_KEY")
[ -z "$N8N_DB_NAME" ] && MISSING_VARS+=("N8N_DB_NAME")
[ -z "$N8N_DB_USER" ] && MISSING_VARS+=("N8N_DB_USER")
[ -z "$N8N_DB_PASSWORD" ] && MISSING_VARS+=("N8N_DB_PASSWORD")
[ -z "$REDIS_HOST" ] && MISSING_VARS+=("REDIS_HOST")

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
    log_error "Critical n8n environment variables are empty:"
    for var in "${MISSING_VARS[@]}"; do
        log_error "  - $var"
    done
    exit 1
fi
log_success "✓ All n8n environment variables validated"
echo ""

# Create Docker Compose file
log_step "Step 7: Creating Docker Compose configuration"
COMPOSE_FILE_CREATED=true

# Generate docker-compose content with expanded variables
DOCKER_COMPOSE_CONTENT="version: '3.8'

services:
  n8n:
    image: n8nio/n8n:latest
    container_name: $CONTAINER_NAME
    restart: unless-stopped
    ports:
      - \"127.0.0.1:5678:5678\"
    environment:
      # Database (PostgreSQL)
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=$N8N_DB_NAME
      - DB_POSTGRESDB_USER=$N8N_DB_USER
      - DB_POSTGRESDB_PASSWORD=$N8N_DB_PASSWORD
      
      # Encryption
      - N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
      
      # Domain and SSL settings
      - N8N_HOST=$N8N_DOMAIN
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://$N8N_DOMAIN/
      - GENERIC_TIMEZONE=\${TZ:-Europe/Bucharest}
"

# Add Redis configuration only for queue mode
if [ "$EXECUTION_MODE" = "queue" ]; then
    DOCKER_COMPOSE_CONTENT+="      
      # Redis for Queue and Cache (connects to host Redis via vps_network gateway)
      - QUEUE_BULL_REDIS_HOST=$REDIS_HOST
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_DB=0
      - QUEUE_BULL_REDIS_PASSWORD=$REDIS_PASSWORD
      - QUEUE_BULL_REDIS_TIMEOUT_THRESHOLD=30000
      - QUEUE_BULL_REDIS_CONNECT_TIMEOUT=30000
"
fi

DOCKER_COMPOSE_CONTENT+="      
      # Execution Mode
      - EXECUTIONS_MODE=$EXECUTION_MODE
"

# Continue with remaining config
DOCKER_COMPOSE_CONTENT+="
      # Logs
      - N8N_LOG_LEVEL=info
      - N8N_LOG_OUTPUT=console
      
    volumes:
      - $DATA_DIR/.n8n:/home/node/.n8n
      
    networks:
      - n8n_network
      - vps_network
      
    healthcheck:
      test: [\"CMD-SHELL\", \"wget --no-verbose --tries=1 --spider http://localhost:5678/healthz || exit 1\"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

networks:
  n8n_network:
    external: true
  vps_network:
    external: true"

# Write docker-compose file with sudo
echo "$DOCKER_COMPOSE_CONTENT" | run_sudo tee "$DATA_DIR/docker-compose.yml" > /dev/null

log_success "Docker Compose configuration created"
echo ""

# Deploy container
log_step "Step 8: Deploying n8n container"
if ! deploy_with_compose "$DATA_DIR"; then
    log_error "Failed to deploy n8n"
    exit 1
fi
echo ""

# Connect Redis to n8n_network for communication
log_step "Step 9: Connecting services to n8n network"

# Connect Redis
if run_sudo docker ps --format '{{.Names}}' | grep -q "^redis$"; then
    if run_sudo docker network inspect n8n_network --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "^redis$"; then
        log_info "✓ Redis already connected to n8n_network"
    else
        log_info "Connecting Redis container to n8n_network..."
        run_sudo docker network connect n8n_network redis
        log_success "✓ Redis connected to n8n_network"
    fi
else
    log_warn "Redis container not found - queue mode may not work"
fi

# Connect Ollama (if exists)
if run_sudo docker ps --format '{{.Names}}' | grep -q "^ollama$"; then
    if run_sudo docker network inspect n8n_network --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "^ollama$"; then
        log_info "✓ Ollama already connected to n8n_network"
    else
        log_info "Connecting Ollama container to n8n_network..."
        run_sudo docker network connect n8n_network ollama
        log_success "✓ Ollama connected to n8n_network"
    fi
else
    log_info "Ollama not installed (add it via orchestrator optional dependencies)"
fi
echo ""

# Wait for container to be ready
log_step "Step 10: Waiting for n8n to be ready"
RETRIES=60
COUNT=0
while [ $COUNT -lt $RETRIES ]; do
    if run_sudo docker exec $CONTAINER_NAME wget --no-verbose --tries=1 --spider http://localhost:5678/healthz 2>/dev/null; then
        log_success "n8n is ready!"
        break
    fi
    COUNT=$((COUNT + 1))
    if [ $COUNT -eq $RETRIES ]; then
        log_error "n8n failed to become ready"
        run_sudo docker logs $CONTAINER_NAME --tail 50
        exit 1
    fi
    sleep 2
done
echo ""

# Configure Nginx reverse proxy
log_step "Step 11: Configuring Nginx reverse proxy"

cat << 'EOF_NGINX' | run_sudo tee "/etc/nginx/sites-available/$APP_NAME.conf" > /dev/null
# n8n Workflow Automation - Nginx Configuration
# Domain: $N8N_DOMAIN
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

server {
    listen 80;
    listen [::]:80;
    server_name $N8N_DOMAIN;

    # Security headers
    include snippets/security.conf;

    # Logging
    access_log /var/log/nginx/n8n_access.log;
    error_log /var/log/nginx/n8n_error.log warn;

    # Let's Encrypt ACME challenge
    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root /var/www/html;
    }

    # n8n application proxy
    location / {
        # Proxy to n8n container (native nginx -> Docker container via exposed port)
        # Note: If nginx runs in Docker on vps_network, use: http://n8n:5678
        proxy_pass http://127.0.0.1:5678;
        proxy_http_version 1.1;
        
        # WebSocket support (required for n8n real-time features)
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Standard proxy headers
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;
        
        # Extended timeouts for long-running workflows
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        
        # Buffer settings (disabled for streaming)
        proxy_buffering off;
        proxy_request_buffering off;
        
        # Security
        proxy_hide_header X-Powered-By;
        
        # Additional headers for n8n
        proxy_set_header X-Scheme $scheme;
    }

    # Health check endpoint (optional monitoring)
    location /healthz {
        proxy_pass http://127.0.0.1:5678/healthz;
        access_log off;
        proxy_connect_timeout 5s;
        proxy_read_timeout 5s;
    }

    # Deny access to sensitive files
    location ~ /\\.(?!well-known).* {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF_NGINX
# Now substitute variables manually
run_sudo sed -i "s|\$N8N_DOMAIN|$N8N_DOMAIN|g" "/etc/nginx/sites-available/$APP_NAME.conf"

log_success "Nginx configuration created in sites-available"

# Enable site by creating symlink
run_sudo ln -sf "/etc/nginx/sites-available/$APP_NAME.conf" "/etc/nginx/sites-enabled/$APP_NAME.conf"
log_success "Symlink created in sites-enabled"

# Test Nginx configuration
if run_sudo nginx -t 2>&1 | grep -q "test is successful"; then
    log_success "Nginx configuration is valid"
    run_sudo systemctl reload nginx
    log_success "Nginx reloaded"
else
    log_error "Nginx configuration test failed"
    run_sudo nginx -t
    exit 1
fi
echo ""

# Request SSL certificate
log_step "Step 12: Requesting SSL certificate"
echo ""

# Check if certificate already exists
CERT_PATH="/etc/letsencrypt/live/$N8N_DOMAIN"
if run_sudo test -d "$CERT_PATH" && run_sudo test -f "$CERT_PATH/fullchain.pem"; then
    log_success "SSL certificate already exists for $N8N_DOMAIN"
    log_info "Certificate path: $CERT_PATH"
    audit_log "SSL_EXISTS" "$APP_NAME" "Domain: $N8N_DOMAIN"
    echo ""
else
    log_info "SSL Certificate Setup for: $N8N_DOMAIN"
    echo ""
    log_info "Choose SSL certificate type:"
    echo "  1) Let's Encrypt (certbot) - Free, trusted, auto-renewable"
    echo "  2) Self-signed - Quick, no DNS required, Cloudflare compatible"
    echo ""
    read -p "Enter choice [1-2]: " CERT_CHOICE
    echo ""
    
    case $CERT_CHOICE in
        1)
            log_info "Using Let's Encrypt (certbot)"
            
            # Check if certbot is available, install if not
            if ! command -v certbot &>/dev/null; then
                log_warn "Certbot is not installed"
                log_info "Installing certbot automatically..."
                echo ""
                
                # Find and run certbot installer
                CERTBOT_INSTALLER="${SCRIPT_DIR}/apps/infrastructure/certbot/install.sh"
                if [ -f "$CERTBOT_INSTALLER" ]; then
                    bash "$CERTBOT_INSTALLER"
                    
                    # Verify installation
                    if ! command -v certbot &>/dev/null; then
                        log_error "Failed to install certbot"
                        exit 1
                    fi
                    log_success "Certbot installed successfully"
                    echo ""
                else
                    log_error "Certbot installer not found: $CERTBOT_INSTALLER"
                    exit 1
                fi
            else
                log_success "✓ Certbot is already installed"
            fi
            
            log_info "Email for Let's Encrypt notifications: $N8N_EMAIL"
            echo ""
            log_warn "IMPORTANT: Ensure your domain DNS points to this server!"
            log_info "Server IP: $(hostname -I | awk '{print $1}')"
            echo ""
            log_info "Requesting certificate from Let's Encrypt..."
            echo ""
            
            # Create log directory
            CERT_LOG_DIR="/var/log/my-scripts"
            run_sudo mkdir -p "$CERT_LOG_DIR"
            CERT_LOG_FILE="$CERT_LOG_DIR/certbot_n8n_$(date +%Y%m%d_%H%M%S).log"
            
            # Request certificate automatically (capture exit code properly)
            set +e  # Temporarily disable exit on error
            run_sudo certbot --nginx -d "$N8N_DOMAIN" \
                --email "$N8N_EMAIL" \
                --agree-tos \
                --no-eff-email \
                --redirect \
                --non-interactive 2>&1 | run_sudo tee "$CERT_LOG_FILE"
            CERTBOT_EXIT_CODE=${PIPESTATUS[0]}
            set -e  # Re-enable exit on error
            
            echo ""
            log_info "Certbot exit code: $CERTBOT_EXIT_CODE"
            log_info "Full log saved to: $CERT_LOG_FILE"
            echo ""
            
            if [ $CERTBOT_EXIT_CODE -eq 0 ]; then
                log_success "SSL certificate installed successfully!"
                audit_log "SSL_CONFIGURED" "$APP_NAME" "Domain: $N8N_DOMAIN"
                echo ""
                log_info "Your n8n is now accessible at: https://$N8N_DOMAIN"
            else
                # Check if it's a rate limit error
                if grep -q "too many certificates" "$CERT_LOG_FILE" 2>/dev/null || grep -q "rate limit" "$CERT_LOG_FILE" 2>/dev/null; then
                    log_error "Let's Encrypt rate limit reached!"
                    echo ""
                    log_warn "Let's Encrypt has a limit of 5 certificates per week for the same domain."
                    log_info "Using self-signed certificate as fallback..."
                    echo ""
                    
                    # Generate self-signed certificate
                    if [ -f "${SCRIPT_DIR}/tools/generate-self-signed-cert.sh" ]; then
                        bash "${SCRIPT_DIR}/tools/generate-self-signed-cert.sh" "$N8N_DOMAIN"
                        
                        if run_sudo test -f "$CERT_PATH/fullchain.pem"; then
                            log_success "Self-signed certificate created successfully"
                            audit_log "SSL_SELF_SIGNED" "$APP_NAME" "Domain: $N8N_DOMAIN"
                            echo ""
                            log_warn "IMPORTANT: Set Cloudflare SSL mode to 'Full' (not 'Full Strict')"
                            log_info "Cloudflare Dashboard → SSL/TLS → Overview → Full"
                        else
                            log_error "Failed to create self-signed certificate"
                            exit 1
                        fi
                    else
                        log_error "Self-signed cert generator not found: ${SCRIPT_DIR}/tools/generate-self-signed-cert.sh"
                        exit 1
                    fi
                else
                    log_error "Failed to obtain SSL certificate (exit code: $CERTBOT_EXIT_CODE)"
                    echo ""
                    log_info "Common reasons:"
                    log_info "  • DNS is not pointing to this server"
                    log_info "  • Port 80/443 not accessible from internet"
                    log_info "  • Domain is already using a certificate"
                    log_info "  • Rate limit (5 certs per week) - check log for details"
                    echo ""
                    log_info "Check the log for details: $CERT_LOG_FILE"
                    exit 1
                fi
            fi
            ;;
        2)
            log_info "Using Self-signed certificate"
            echo ""
            
            # Generate self-signed certificate
            if [ -f "${SCRIPT_DIR}/tools/generate-self-signed-cert.sh" ]; then
                bash "${SCRIPT_DIR}/tools/generate-self-signed-cert.sh" "$N8N_DOMAIN"
                
                if run_sudo test -f "$CERT_PATH/fullchain.pem"; then
                    log_success "Self-signed certificate created successfully"
                    audit_log "SSL_SELF_SIGNED" "$APP_NAME" "Domain: $N8N_DOMAIN"
                    echo ""
                    log_warn "IMPORTANT: Set Cloudflare SSL mode to 'Full' (not 'Full Strict')"
                    log_info "Cloudflare Dashboard → SSL/TLS → Overview → Full"
                    echo ""
                else
                    log_error "Failed to create self-signed certificate"
                    exit 1
                fi
            else
                log_error "Self-signed cert generator not found: ${SCRIPT_DIR}/tools/generate-self-signed-cert.sh"
                exit 1
            fi
            ;;
        *)
            log_error "Invalid choice. Please enter 1 or 2"
            exit 1
            ;;
    esac
fi
echo ""

# Update Nginx configuration with SSL after certificate is created
log_step "Step 13: Updating Nginx configuration with SSL"
log_info "Adding SSL configuration to nginx..."

# Verify certificate exists before updating nginx config
if run_sudo test -f "$CERT_PATH/fullchain.pem" && run_sudo test -f "$CERT_PATH/privkey.pem"; then
    log_success "✓ SSL certificates found"
    
    # Create new nginx config with SSL
    cat << 'EOF_NGINX_SSL' | run_sudo tee "/etc/nginx/sites-available/$APP_NAME.conf" > /dev/null
# n8n Workflow Automation - Nginx Configuration with SSL
# Domain: $N8N_DOMAIN
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

# HTTP - Redirect to HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $N8N_DOMAIN;

    # Let's Encrypt ACME challenge
    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root /var/www/html;
    }

    # Redirect all other traffic to HTTPS
    location / {
        return 301 https://$host$request_uri;
    }
}

# HTTPS - Main n8n server
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $N8N_DOMAIN;

    # SSL Certificate (works for both certbot and self-signed)
    ssl_certificate /etc/letsencrypt/live/$N8N_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$N8N_DOMAIN/privkey.pem;
    
    # SSL Configuration
    include snippets/ssl-params.conf;
    
    # Security headers
    include snippets/security.conf;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

    # Logging
    access_log /var/log/nginx/n8n_access.log;
    error_log /var/log/nginx/n8n_error.log warn;

    # n8n application proxy
    location / {
        # Proxy to n8n container
        proxy_pass http://127.0.0.1:5678;
        proxy_http_version 1.1;
        
        # WebSocket support (required for n8n real-time features)
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Standard proxy headers
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;
        
        # Extended timeouts for long-running workflows
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        
        # Buffer settings (disabled for streaming)
        proxy_buffering off;
        proxy_request_buffering off;
        
        # Security
        proxy_hide_header X-Powered-By;
        
        # Additional headers for n8n
        proxy_set_header X-Scheme $scheme;
    }

    # Health check endpoint (optional monitoring)
    location /healthz {
        proxy_pass http://127.0.0.1:5678/healthz;
        access_log off;
        proxy_connect_timeout 5s;
        proxy_read_timeout 5s;
    }

    # Deny access to sensitive files
    location ~ /\\.(?!well-known).* {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF_NGINX_SSL

    # Substitute variables
    run_sudo sed -i "s|\$N8N_DOMAIN|$N8N_DOMAIN|g" "/etc/nginx/sites-available/$APP_NAME.conf"
    
    log_success "Nginx SSL configuration created"
    
    # Test nginx configuration
    if run_sudo nginx -t 2>&1 | grep -q "test is successful"; then
        log_success "✓ Nginx configuration is valid"
        
        # Reload nginx to apply SSL config
        log_info "Reloading Nginx to apply SSL configuration..."
        run_sudo systemctl reload nginx
        
        if systemctl is-active --quiet nginx; then
            log_success "✓ Nginx reloaded successfully with SSL"
        else
            log_error "Nginx failed to reload"
            run_sudo nginx -t
            exit 1
        fi
    else
        log_error "Nginx configuration test failed"
        run_sudo nginx -t
        exit 1
    fi
else
    log_warn "SSL certificates not found, keeping HTTP-only configuration"
    log_warn "You can run certbot manually later and update nginx config"
fi
echo ""

# Display connection info
log_success "═══════════════════════════════════════════"
log_success "  n8n Installation Complete!"
log_success "═══════════════════════════════════════════"
audit_log "INSTALL_COMPLETE" "$APP_NAME" "Domain: $N8N_DOMAIN, DB: $N8N_DB_NAME"
echo ""

display_connection_info "$APP_NAME" "N8N_USER" "N8N_PASSWORD"
echo ""

log_info "Access Information:"
echo "  Domain: $N8N_DOMAIN"
echo "  Web Interface: https://$N8N_DOMAIN (or http:// if SSL skipped)"
echo "  Local Access: http://localhost:5678"
echo "  Health Check: http://localhost:5678/healthz"
echo ""

log_info "Database Configuration:"
echo "  Type: PostgreSQL"
echo "  Database: $N8N_DB_NAME"
echo "  User: $N8N_DB_USER"
echo "  Host: postgres (Docker network: $NETWORK)"
echo "  Production-ready persistent storage"
echo ""

log_info "⚡ Redis Cache & Queue:"
echo "  Host: $REDIS_HOST (Redis container)"
echo "  Port: 6379"
echo "  Mode: $EXECUTION_MODE"
echo "  Connection: via n8n_network (dynamically connected)"
echo ""

# Display Ollama status if it was installed or detected
if run_sudo docker ps --format '{{.Names}}' | grep -q "^ollama$"; then
    log_info "AI Integration - Ollama:"
    echo "  Status: Installed and connected"
    echo "  Access: http://ollama:11434 (from n8n workflows)"
    echo "  Models: docker exec ollama ollama list"
    echo "  Pull model: docker exec ollama ollama pull mistral"
    echo "  Use in n8n: Add 'Ollama' node to workflows"
    echo ""
fi

log_info "Security & SSL:"
echo "  Domain: $N8N_DOMAIN"
echo "  Email: $N8N_EMAIL"
echo "  Auto-renewal: Enabled (certbot timer)"
echo "  Data Encryption: Active"
echo ""

log_info "� Nginx Configuration:"
echo "  Config file: /etc/nginx/sites-available/$APP_NAME.conf"
echo "  Symlink: /etc/nginx/sites-enabled/$APP_NAME.conf"
echo "  Access log: /var/log/nginx/n8n_access.log"
echo "  Error log: /var/log/nginx/n8n_error.log"
echo ""
log_info "Nginx commands:"
echo "  Test config:  sudo nginx -t"
echo "  Reload:       sudo systemctl reload nginx"
echo "  View logs:    sudo tail -f /var/log/nginx/n8n_access.log"
echo ""

log_info "Docker Management:"
echo "  View logs:    docker logs $CONTAINER_NAME -f"
echo "  Restart:      docker restart $CONTAINER_NAME"
echo "  Stop:         docker stop $CONTAINER_NAME"
echo "  Start:        docker start $CONTAINER_NAME"
echo "  Remove:       cd $DATA_DIR && docker-compose down"
echo "  Network:      docker network inspect $NETWORK"
echo ""

log_info "Credentials Storage:"
echo "  Location: ~/.vps-secrets/.env_$APP_NAME"
echo "  Contains: Domain, Email, DB credentials, N8N credentials"
echo "  Permissions: 600 (owner read/write only)"
echo ""

log_info "Workflow examples:"
echo "  • Schedule tasks (cron-based triggers)"
echo "  • Webhook automation (HTTPS webhooks)"
echo "  • Email notifications (SMTP integration)"
echo "  • Database operations (SQL queries)"
echo "  • API integrations (300+ services)"
echo "  • File processing (CSV, JSON, XML)"
echo ""

log_info "Popular integrations:"
echo "  • Slack, Discord, Telegram"
echo "  • Google Sheets, Drive, Calendar"
echo "  • GitHub, GitLab"
echo "  • PostgreSQL, MySQL, MongoDB"
echo "  • HTTP Request, Webhook"
echo "  • Cron (scheduled workflows)"
echo ""

log_info "Next steps:"
echo "  1. Access https://$N8N_DOMAIN"
echo "  2. Login with generated credentials"
echo "  3. Create your first workflow"
echo "  4. Test with simple HTTP request node"
echo "  5. Configure webhooks (HTTPS enabled)"
echo "  6. Explore workflow templates"
echo ""

log_info "Documentation:"
echo "  • Official docs: https://docs.n8n.io"
echo "  • Workflow templates: https://n8n.io/workflows"
echo "  • Community: https://community.n8n.io"
echo ""


