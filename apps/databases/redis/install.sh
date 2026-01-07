#!/bin/bash

# ==============================================================================
# REDIS CACHE/DATABASE INSTALLATION (NATIVE)
# Installs Redis directly on host for maximum performance and low latency
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"

APP_NAME="redis"
CONF_FILE="/etc/redis/redis.conf"
DATA_DIR="/var/lib/redis"
LOG_FILE="/var/log/redis/redis-server.log"

log_info "═══════════════════════════════════════════"
log_info "  Installing Redis Cache/Database (Native)"
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
if systemctl is-active --quiet redis-server 2>/dev/null || systemctl is-active --quiet redis 2>/dev/null; then
    log_warn "Redis is already running"
    if confirm_action "Reinstall/Reconfigure? (This will overwrite configs!)"; then
        log_info "Proceeding with reconfiguration..."
    else
        log_info "Installation cancelled"
        exit 0
    fi
elif command -v redis-server &>/dev/null; then
    log_warn "Redis is installed but NOT running"
    
    if confirm_action "Start Redis service instead of reinstalling?"; then
        log_info "Starting Redis..."
        
        # Determine service name
        if systemctl status redis-server &>/dev/null || systemctl is-enabled redis-server &>/dev/null 2>&1; then
            SERVICE="redis-server"
        else
            SERVICE="redis"
        fi
        
        run_sudo systemctl start "$SERVICE"
        if systemctl is-active --quiet "$SERVICE"; then
            log_success "Redis started successfully"
            exit 0
        else
            log_error "Failed to start Redis. Check logs."
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

# Install Redis
log_step "Step 2: Installing Redis"
pkg_update

if is_debian_based; then
    pkg_install redis-server redis-tools
elif is_rhel_based; then
    pkg_install epel-release
    pkg_install redis
else
    log_error "Unsupported OS: $OS_ID"
    exit 1
fi

log_success "Redis installed"
echo ""

# Manage credentials
log_step "Step 3: Setting up Redis password"

if has_credentials "$APP_NAME"; then
    log_info "Using existing password from credentials store"
    REDIS_PASSWORD=$(get_secret "$APP_NAME" "REDIS_PASSWORD")
else
    log_info "Generating secure password..."
    REDIS_PASSWORD=$(generate_secure_password 32 "alphanumeric")
    save_secret "$APP_NAME" "REDIS_PASSWORD" "$REDIS_PASSWORD"
    log_success "Password saved to credentials store"
fi

# Validate password was set
if [ -z "$REDIS_PASSWORD" ]; then
    log_error "Failed to generate or retrieve Redis password!"
    exit 1
fi
log_info "Redis password: ${REDIS_PASSWORD:0:8}... (${#REDIS_PASSWORD} chars)"
echo ""

# Configure Redis
log_step "Step 4: Configuring Redis"

# Stop Redis service before modifying config
if systemctl is-active --quiet redis-server 2>/dev/null; then
    log_info "Stopping Redis service..."
    run_sudo systemctl stop redis-server
elif systemctl is-active --quiet redis 2>/dev/null; then
    log_info "Stopping Redis service..."
    run_sudo systemctl stop redis
fi

# Backup original config
if [ -f "$CONF_FILE" ]; then
    run_sudo cp "$CONF_FILE" "${CONF_FILE}.backup_$(date +%Y%m%d_%H%M%S)"
fi

# Detect Docker gateway IPs for bind configuration
log_info "Detecting Docker network gateways..."
BIND_IPS="127.0.0.1 ::1"

# Add docker0 bridge IP if exists
if ip addr show docker0 &>/dev/null; then
    DOCKER0_IP=$(ip -4 addr show docker0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    if [ -n "$DOCKER0_IP" ]; then
        BIND_IPS="$BIND_IPS $DOCKER0_IP"
        log_info "Found docker0: $DOCKER0_IP"
    fi
fi

# Add all custom Docker network gateways (including vps_network)
log_info "Detecting all Docker network gateways for Redis bind..."
if command -v docker &>/dev/null; then
    # Only proceed if Docker daemon is running
    if systemctl is-active --quiet docker 2>/dev/null; then
        # Try to get Docker networks, but don't fail if it doesn't work
        set +e  # Temporarily disable exit on error
        CUSTOM_GATEWAYS=$(run_sudo docker network ls --filter driver=bridge -q 2>/dev/null | \
            xargs -r run_sudo docker network inspect --format '{{range .IPAM.Config}}{{.Gateway}} {{end}}' 2>/dev/null | \
        tr ' ' '\n' | grep -E '^[0-9]+\.' | sort -u | grep -v '^$')
        DOCKER_CMD_EXIT=$?
        set -e  # Re-enable exit on error
        
        if [ $DOCKER_CMD_EXIT -eq 0 ] && [ -n "$CUSTOM_GATEWAYS" ]; then
            for GW in $CUSTOM_GATEWAYS; do
                # Skip docker0 IP if already added
                if [ "$GW" != "$DOCKER0_IP" ]; then
                    BIND_IPS="$BIND_IPS $GW"
                    log_info "Found Docker network gateway: $GW"
                fi
            done
        else
            log_debug "Could not detect Docker networks (may need docker group membership)"
        fi
    else
        log_debug "Docker daemon not running, skipping custom network detection"
    fi
fi

log_success "Redis will bind to: $BIND_IPS"
echo ""

# Modify Redis configuration (preserve APT defaults, add our changes)
# This approach comments original lines and adds our settings below them
# Safer than overwriting: prevents conflicts with package updates
log_info "Modifying Redis configuration..."

# Backup original config if not already backed up
if [ ! -f "${CONF_FILE}.original" ]; then
    run_sudo cp "$CONF_FILE" "${CONF_FILE}.original"
    log_info "Backed up original config to ${CONF_FILE}.original"
fi

# 1. Modify bind address (comment default, add ours)
log_info "Setting bind addresses: $BIND_IPS"
if run_sudo grep -q "^# Commented by my-scripts - bind" "$CONF_FILE"; then
    # Already modified - just update the active bind line with current networks
    log_info "Config already modified, updating bind line..."
    run_sudo sed -i "/^# Commented by my-scripts - bind/{ n; s|^bind .*|bind $BIND_IPS|; }" "$CONF_FILE"
else
    # First time - find first active bind line, comment it, add ours below
    log_info "First time setup, commenting original and adding new bind line..."
    # Find the line number of the first uncommented bind line
    BIND_LINE=$(run_sudo grep -n "^bind " "$CONF_FILE" | head -1 | cut -d: -f1)
    if [ -n "$BIND_LINE" ]; then
        # Comment the line and add marker
        run_sudo sed -i "${BIND_LINE}s|^|# Commented by my-scripts - |" "$CONF_FILE"
        # Add new bind line right after it
        run_sudo sed -i "${BIND_LINE}a bind $BIND_IPS" "$CONF_FILE"
        log_success "Commented original bind line and added new configuration"
    else
        log_warn "No active bind line found, adding at end of file"
        echo "bind $BIND_IPS" | run_sudo tee -a "$CONF_FILE" > /dev/null
    fi
fi

# 2. Modify protected-mode (comment default, add ours)
log_info "Disabling protected-mode for Docker network access..."
if run_sudo grep -q "^# Commented by my-scripts - protected-mode" "$CONF_FILE"; then
    # Already modified - update the active line
    run_sudo sed -i "/^# Commented by my-scripts - protected-mode/{ n; s|^protected-mode .*|protected-mode no|; }" "$CONF_FILE"
else
    # First time - find active protected-mode line, comment it, add ours
    PROT_LINE=$(run_sudo grep -n "^protected-mode " "$CONF_FILE" | head -1 | cut -d: -f1)
    if [ -n "$PROT_LINE" ]; then
        run_sudo sed -i "${PROT_LINE}s|^|# Commented by my-scripts - |" "$CONF_FILE"
        run_sudo sed -i "${PROT_LINE}a protected-mode no" "$CONF_FILE"
        log_success "Disabled protected-mode"
    else
        echo "protected-mode no" | run_sudo tee -a "$CONF_FILE" > /dev/null
    fi
fi

# 3. Set password (comment default commented line, add ours)
log_info "Setting Redis password..."
if run_sudo grep -q "^requirepass " "$CONF_FILE"; then
    # Already has active requirepass - update it
    log_info "Active requirepass found, updating..."
    run_sudo sed -i "s|^requirepass .*|requirepass $REDIS_PASSWORD|" "$CONF_FILE"
elif run_sudo grep -q "^# Commented by my-scripts - # requirepass" "$CONF_FILE"; then
    # Already modified - update the active line
    run_sudo sed -i "/^# Commented by my-scripts - # requirepass/{ n; s|^requirepass .*|requirepass $REDIS_PASSWORD|; }" "$CONF_FILE"
else
    # First time - find commented requirepass, comment it with our marker, add ours
    REQ_LINE=$(run_sudo grep -n "^# requirepass " "$CONF_FILE" | head -1 | cut -d: -f1)
    if [ -n "$REQ_LINE" ]; then
        run_sudo sed -i "${REQ_LINE}s|^# |# Commented by my-scripts - # |" "$CONF_FILE"
        run_sudo sed -i "${REQ_LINE}a requirepass $REDIS_PASSWORD" "$CONF_FILE"
        log_success "Set Redis password"
    else
        echo "requirepass $REDIS_PASSWORD" | run_sudo tee -a "$CONF_FILE" > /dev/null
    fi
fi

# 4. Set supervised to systemd (comment default, add ours)
log_info "Configuring systemd supervision..."
if run_sudo grep -q "^supervised " "$CONF_FILE"; then
    run_sudo sed -i '/^supervised /s/^/# Commented by my-scripts - /' "$CONF_FILE"
    run_sudo sed -i '/# Commented by my-scripts - supervised /a supervised systemd' "$CONF_FILE"
else
    # Add after daemonize if supervised doesn't exist
    run_sudo sed -i '/^daemonize yes/a supervised systemd' "$CONF_FILE"
fi

# 5. Enable AOF persistence (comment default, add ours)
log_info "Enabling AOF persistence..."
if run_sudo grep -q "^# Commented by my-scripts - appendonly" "$CONF_FILE"; then
    # Already modified - update the active line
    run_sudo sed -i "/^# Commented by my-scripts - appendonly/{ n; s|^appendonly .*|appendonly yes|; }" "$CONF_FILE"
else
    # First time - find active appendonly line, comment it, add ours
    APP_LINE=$(run_sudo grep -n "^appendonly " "$CONF_FILE" | head -1 | cut -d: -f1)
    if [ -n "$APP_LINE" ]; then
        run_sudo sed -i "${APP_LINE}s|^|# Commented by my-scripts - |" "$CONF_FILE"
        run_sudo sed -i "${APP_LINE}a appendonly yes" "$CONF_FILE"
        log_success "Enabled AOF persistence"
    else
        echo "appendonly yes" | run_sudo tee -a "$CONF_FILE" > /dev/null
    fi
fi

# 6. Set maxmemory-policy (add if not exists, otherwise modify)
log_info "Setting memory management policy..."
if run_sudo grep -q "^maxmemory-policy" "$CONF_FILE"; then
    run_sudo sed -i '/^maxmemory-policy /s/^/# Commented by my-scripts - /' "$CONF_FILE"
    run_sudo sed -i '/# Commented by my-scripts - maxmemory-policy /a maxmemory-policy allkeys-lru' "$CONF_FILE"
elif run_sudo grep -q "^# maxmemory-policy" "$CONF_FILE"; then
    run_sudo sed -i '/^# maxmemory-policy /s/^/# Commented by my-scripts - /' "$CONF_FILE"
    run_sudo sed -i '/# Commented by my-scripts - # maxmemory-policy /a maxmemory-policy allkeys-lru' "$CONF_FILE"
else
    # Add after maxmemory if it exists, or at end
    if run_sudo grep -q "^# maxmemory " "$CONF_FILE"; then
        run_sudo sed -i '/^# maxmemory /a maxmemory-policy allkeys-lru' "$CONF_FILE"
    else
        echo "maxmemory-policy allkeys-lru" | run_sudo tee -a "$CONF_FILE" > /dev/null
    fi
fi

# 7. Set log file location (comment default, add ours)
log_info "Setting log file location: $LOG_FILE"
if run_sudo grep -q "^# Commented by my-scripts - logfile" "$CONF_FILE"; then
    # Already modified - update the path
    run_sudo sed -i "/^# Commented by my-scripts - logfile/{ n; s|^logfile .*|logfile $LOG_FILE|; }" "$CONF_FILE"
else
    # First time - find active logfile line, comment it, add ours
    LOG_LINE=$(run_sudo grep -n "^logfile " "$CONF_FILE" | head -1 | cut -d: -f1)
    if [ -n "$LOG_LINE" ]; then
        run_sudo sed -i "${LOG_LINE}s|^|# Commented by my-scripts - |" "$CONF_FILE"
        run_sudo sed -i "${LOG_LINE}a logfile $LOG_FILE" "$CONF_FILE"
        log_success "Set log file location"
    else
        echo "logfile $LOG_FILE" | run_sudo tee -a "$CONF_FILE" > /dev/null
    fi
fi

# 8. Set data directory (comment default, add ours)
log_info "Setting data directory: $DATA_DIR"
if run_sudo grep -q "^# Commented by my-scripts - dir" "$CONF_FILE"; then
    # Already modified - update the path
    run_sudo sed -i "/^# Commented by my-scripts - dir/{ n; s|^dir .*|dir $DATA_DIR|; }" "$CONF_FILE"
else
    # First time - find active dir line, comment it, add ours
    DIR_LINE=$(run_sudo grep -n "^dir " "$CONF_FILE" | head -1 | cut -d: -f1)
    if [ -n "$DIR_LINE" ]; then
        run_sudo sed -i "${DIR_LINE}s|^|# Commented by my-scripts - |" "$CONF_FILE"
        run_sudo sed -i "${DIR_LINE}a dir $DATA_DIR" "$CONF_FILE"
        log_success "Set data directory"
    else
        echo "dir $DATA_DIR" | run_sudo tee -a "$CONF_FILE" > /dev/null
    fi
fi

# Verify all critical settings were applied correctly
log_info "Verifying configuration changes..."

VERIFY_FAILED=0

# Check bind addresses
if ! run_sudo grep "^bind.*127.0.0.1" "$CONF_FILE" | grep -qv "^#"; then
    log_error "Verification failed: bind addresses not set correctly"
    VERIFY_FAILED=1
else
    log_success "✓ Bind configuration verified"
fi

# Check protected-mode
if ! run_sudo grep "^protected-mode no" "$CONF_FILE" | grep -qv "^#"; then
    log_error "Verification failed: protected-mode not disabled"
    VERIFY_FAILED=1
else
    log_success "✓ Protected-mode set to 'no'"
fi

# Check requirepass
if ! run_sudo grep "^requirepass" "$CONF_FILE" | grep -qv "^#"; then
    log_error "Verification failed: requirepass not set"
    VERIFY_FAILED=1
else
    log_success "✓ Redis password configured"
fi

# Check supervised (non-critical)
if run_sudo grep "^supervised systemd" "$CONF_FILE" | grep -qv "^#"; then
    log_success "✓ Systemd supervision enabled"
else
    log_warn "Warning: supervised systemd not set (non-critical)"
fi

# Check appendonly (non-critical)
if run_sudo grep "^appendonly yes" "$CONF_FILE" | grep -qv "^#"; then
    log_success "✓ AOF persistence enabled"
else
    log_warn "Warning: appendonly not enabled (non-critical)"
fi

if [ $VERIFY_FAILED -eq 1 ]; then
    log_error "Redis configuration verification failed - check $CONF_FILE"
    return 1
fi

# Set proper ownership and permissions
run_sudo chown redis:redis "$CONF_FILE"
run_sudo chmod 640 "$CONF_FILE"
log_success "Redis configured"
echo ""

# Setup directories and permissions
log_step "Step 5: Setting up directories"
run_sudo mkdir -p "$DATA_DIR"
run_sudo mkdir -p "$(dirname "$LOG_FILE")"
run_sudo chown -R redis:redis "$DATA_DIR"
run_sudo chown -R redis:redis "$(dirname "$LOG_FILE")"
run_sudo chmod 750 "$DATA_DIR"
log_success "Directories configured"
echo ""

# Configure systemd service
log_step "Step 6: Configuring systemd service"

# Determine service name (different on Ubuntu vs CentOS)
if [ "$PACKAGE_MANAGER" = "apt" ]; then
    SERVICE_NAME="redis-server"
else
    SERVICE_NAME="redis"
fi

run_sudo systemctl enable "$SERVICE_NAME"
run_sudo systemctl restart "$SERVICE_NAME"

# Wait for Redis to start
sleep 2

if systemctl is-active --quiet "$SERVICE_NAME"; then
    log_success "Redis is running"
else
    log_error "Failed to start Redis"
    log_info "Check logs: sudo journalctl -u $SERVICE_NAME -n 50"
    exit 1
fi
echo ""

# Test connection
log_step "Step 7: Testing Redis connection"
if redis-cli -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q "PONG"; then
    log_success "Redis connection test passed"
else
    log_error "Redis connection test failed"
    exit 1
fi
echo ""

# Display installation info
log_success "═══════════════════════════════════════════"
log_success "  Redis Installation Complete!"
log_success "═══════════════════════════════════════════"
echo ""

log_info "Connection Information:"
echo "  Host:     127.0.0.1 (localhost only)"
echo "  Port:     6379"
echo "  Password: $REDIS_PASSWORD"
echo ""

log_info "Configuration:"
echo "  Config File:   $CONF_FILE"
echo "  Data Dir:      $DATA_DIR"
echo "  Log File:      $LOG_FILE"
echo "  Service Name:  $SERVICE_NAME"
echo ""

log_info "Connection Examples:"
cat <<'EXAMPLES'
  # CLI with password:
  redis-cli -a YOUR_PASSWORD
  
  # Test connection:
  redis-cli -a YOUR_PASSWORD ping
  
  # Get info:
  redis-cli -a YOUR_PASSWORD info
  
  # Monitor commands:
  redis-cli -a YOUR_PASSWORD monitor
  
  # NodeJS connection:
  const redis = require('redis');
  const client = redis.createClient({
      host: '127.0.0.1',
      port: 6379,
      password: 'YOUR_PASSWORD'
  });
  
  # Python connection:
  import redis
  r = redis.Redis(
      host='127.0.0.1',
      port=6379,
      password='YOUR_PASSWORD'
  )
EXAMPLES

echo ""
log_info "Useful commands:"
echo "  sudo systemctl status $SERVICE_NAME    # Check status"
echo "  sudo systemctl restart $SERVICE_NAME   # Restart"
echo "  sudo systemctl stop $SERVICE_NAME      # Stop"
echo "  redis-cli -a PASSWORD info            # Get info"
echo "  redis-cli -a PASSWORD dbsize          # Get key count"
echo "  sudo tail -f $LOG_FILE                # View logs"
echo ""

log_info "Performance tuning:"
echo "  • Adjust maxmemory in $CONF_FILE based on available RAM"
echo "  • Monitor memory: redis-cli -a PASSWORD info memory"
echo "  • Monitor stats: redis-cli -a PASSWORD info stats"
echo ""

log_warn "Security Note:"
echo "  • Redis is bound to localhost only (secure)"
echo "  • Password authentication is enabled"
echo "  • Credentials saved in: ~/.vps-secrets/.env_$APP_NAME"
echo "  • To allow remote access, edit bind in $CONF_FILE"
echo ""

log_info "Backup commands:"
echo "  # Manual backup:"
echo "  redis-cli -a PASSWORD save"
echo "  sudo cp $DATA_DIR/dump.rdb /backup/location/"
echo ""
echo "  # Scheduled backup with cron:"
echo "  0 2 * * * redis-cli -a PASSWORD save && cp $DATA_DIR/dump.rdb /backup/redis-\$(date +\\%Y\\%m\\%d).rdb"
echo ""

