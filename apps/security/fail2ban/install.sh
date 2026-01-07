#!/bin/bash

# ==============================================================================
# FAIL2BAN INTRUSION PREVENTION
# Automatic IP banning based on failed authentication attempts
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"

APP_NAME="fail2ban"

log_info "═══════════════════════════════════════════"
log_info "  Installing Fail2ban Intrusion Prevention"
log_info "═══════════════════════════════════════════"
echo ""

# Detect OS
log_step "Step 1: Detecting operating system"
detect_os
log_success "OS detected: $OS_TYPE"
log_info "Package manager: $PACKAGE_MANAGER"
echo ""

# Check if already installed
if systemctl is-active --quiet fail2ban 2>/dev/null; then
    log_warn "Fail2ban is already running"
    if confirm_action "Reinstall/Reconfigure?"; then
        log_info "Proceeding with reconfiguration..."
    else
        log_info "Installation cancelled"
        exit 0
    fi
fi
echo ""

# Install Fail2ban
log_step "Step 2: Installing Fail2ban package"
pkg_update

if is_debian_based; then
    pkg_install fail2ban
elif is_rhel_based; then
    pkg_install epel-release
    pkg_install fail2ban fail2ban-systemd
else
    log_error "Unsupported OS: $OS_ID"
    exit 1
fi

log_success "Fail2ban installed"
echo ""

# Create configuration
log_step "Step 3: Creating custom configuration"

# Backup existing config
if [ -f /etc/fail2ban/jail.local ]; then
    run_sudo cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.backup.$(date +%s)
    log_info "Existing config backed up"
fi

run_sudo tee /etc/fail2ban/jail.local > /dev/null << 'EOF'
[DEFAULT]
# Ban settings
bantime = 3600
findtime = 600
maxretry = 5
destemail = root@localhost
sendername = Fail2Ban
action = %(action_mwl)s

# SSH Protection
[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 3
bantime = 7200

# SSH DDoS Protection
[sshd-ddos]
enabled = true
port = ssh
logpath = %(sshd_log)s
maxretry = 10
findtime = 60
bantime = 3600

# Nginx HTTP Auth
[nginx-http-auth]
enabled = true
port = http,https
logpath = /var/log/nginx/error.log
maxretry = 3

# Nginx Limit Request
[nginx-limit-req]
enabled = true
port = http,https
logpath = /var/log/nginx/error.log
maxretry = 10
findtime = 60
bantime = 600

# Nginx NoScript/BadBot
[nginx-noscript]
enabled = true
port = http,https
logpath = /var/log/nginx/access.log
maxretry = 3

[nginx-badbots]
enabled = true
port = http,https
logpath = /var/log/nginx/access.log
maxretry = 2

# Docker Protection
[docker-auth]
enabled = false
port = 2375,2376
logpath = /var/log/docker.log
maxretry = 3
EOF

log_success "Custom jails configured"
echo ""

# Create monitoring script
log_step "Step 4: Creating monitoring tools"
run_sudo tee /usr/local/bin/fail2ban-status > /dev/null << 'EOFSCRIPT'
#!/bin/bash

BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}════════════════════════════════${NC}"
echo -e "${BLUE}  Fail2ban Status Overview${NC}"
echo -e "${BLUE}════════════════════════════════${NC}"
echo ""

# Service status
if systemctl is-active --quiet fail2ban; then
    echo -e "${GREEN}✅ Fail2ban is running${NC}"
else
    echo -e "${RED}❌ Fail2ban is NOT running${NC}"
    exit 1
fi
echo ""

# Jail status
echo -e "${YELLOW}Active Jails:${NC}"
sudo fail2ban-client status | grep "Jail list" | sed 's/.*://; s/,//g' | xargs -n1 | while read jail; do
    banned=$(sudo fail2ban-client status "$jail" | grep "Currently banned" | awk '{print $NF}')
    total=$(sudo fail2ban-client status "$jail" | grep "Total banned" | awk '{print $NF}')
    echo -e "  • ${GREEN}$jail${NC}: $banned currently banned, $total total"
done
echo ""

# Recently banned IPs
echo -e "${YELLOW}Recently Banned IPs (last 10):${NC}"
sudo zgrep 'Ban' /var/log/fail2ban.log* | tail -10 | awk '{print $NF}' | sort -u | while read ip; do
    echo -e "  • ${RED}$ip${NC}"
done
EOFSCRIPT

run_sudo chmod +x /usr/local/bin/fail2ban-status
log_success "Monitoring script created: fail2ban-status"
echo ""

# Enable and start service
log_step "Step 5: Enabling and starting Fail2ban"
run_sudo systemctl enable fail2ban
run_sudo systemctl restart fail2ban

sleep 3

if systemctl is-active --quiet fail2ban; then
    log_success "Fail2ban is running!"
else
    log_error "Fail2ban failed to start"
    log_info "Check logs: sudo journalctl -u fail2ban -n 50"
    exit 1
fi
echo ""

# Display installation summary
log_success "═══════════════════════════════════════════"
log_success "  Fail2ban Installation Complete!"
log_success "═══════════════════════════════════════════"
echo ""

log_info "⚙️ Configuration:"
echo "  Config:       /etc/fail2ban/jail.local"
echo "  Filters:      /etc/fail2ban/filter.d/"
echo "  Actions:      /etc/fail2ban/action.d/"
echo ""

log_info "🛡️ Active protection:"
echo "  • SSH - Max 3 attempts in 10 minutes (ban: 2 hours)"
echo "  • SSH DDoS - Max 10 attempts in 1 minute"
echo "  • Nginx HTTP Auth - Max 3 attempts"
echo "  • Nginx Rate Limiting"
echo "  • Bad Bots & NoScript protection"
echo ""

log_info "📊 Monitoring commands:"
echo "  Status overview:      sudo fail2ban-status"
echo "  Service status:       sudo systemctl status fail2ban"
echo "  List jails:           sudo fail2ban-client status"
echo "  Jail details:         sudo fail2ban-client status <jail>"
echo "  View logs:            sudo tail -f /var/log/fail2ban.log"
echo ""

log_info "🔧 Management commands:"
echo "  Unban IP:             sudo fail2ban-client set <jail> unbanip <IP>"
echo "  Reload config:        sudo fail2ban-client reload"
echo "  Restart service:      sudo systemctl restart fail2ban"
echo ""

log_warn "⚠️  Important notes:"
echo "  • Default ban time: 1 hour (SSH: 2 hours)"
echo "  • Banned IPs are automatically released after ban time"
echo "  • Configure /etc/fail2ban/jail.local for custom rules"
echo "  • Whitelist your IPs to avoid accidental bans"
echo "  • Monitor logs regularly: /var/log/fail2ban.log"
echo ""

log_info "💡 Customization examples:"
echo "  # Add IP to whitelist:"
echo "  ignoreip = 127.0.0.1/8 YOUR_IP_HERE"
echo ""
echo "  # Increase ban time (in seconds):"
echo "  bantime = 86400  # 24 hours"
echo ""
echo "  # Enable email notifications:"
echo "  destemail = admin@yourdomain.com"
echo "  action = %(action_mwl)s"
echo ""


