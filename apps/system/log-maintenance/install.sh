#!/bin/bash

# ==============================================================================
# LOG MAINTENANCE & SYSTEM CLEANUP
# Automated log rotation, Docker cleanup, and disk space management
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/docker.sh"

APP_NAME="log-maintenance"
SCRIPTS_DIR="/opt/system/maintenance"

log_info "═══════════════════════════════════════════"
log_info "  Installing Log Maintenance System"
log_info "═══════════════════════════════════════════"
echo ""

# Setup directories
log_step "Step 1: Setting up directories"
create_app_directory "$SCRIPTS_DIR"
create_app_directory "$SCRIPTS_DIR/logs"
log_success "Maintenance directories created"
echo ""

# Create comprehensive cleanup script
log_step "Step 2: Creating cleanup scripts"
cat > /usr/local/bin/cleanup-logs << 'EOFCLEANUP'
#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="/opt/system/maintenance/logs/cleanup_$(date +%Y%m%d).log"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}  System Cleanup - $(date)${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
log_msg "Starting system cleanup"
echo ""

# Disk space before
echo -e "${YELLOW}Disk space before cleanup:${NC}"
df -h / | grep -v Filesystem
BEFORE=$(df / | tail -1 | awk '{print $3}')
log_msg "Disk used before: $BEFORE KB"
echo ""

# Clean old system logs
echo -e "${BLUE}1. Cleaning old system logs...${NC}"
log_msg "Cleaning system logs older than 30 days"
FOUND_LOGS=$(find /var/log -type f -name "*.log" -mtime +30 2>/dev/null | wc -l)
if [ "$FOUND_LOGS" -gt 0 ]; then
    find /var/log -type f -name "*.log" -mtime +30 -delete 2>/dev/null || true
    echo -e "  ${GREEN}✓ Removed $FOUND_LOGS old log files${NC}"
    log_msg "Removed $FOUND_LOGS log files"
else
    echo -e "  ${GREEN}✓ No old log files to remove${NC}"
fi
echo ""

# Clean compressed logs
echo -e "${BLUE}2. Cleaning compressed logs...${NC}"
log_msg "Cleaning compressed logs older than 60 days"
FOUND_GZ=$(find /var/log -type f \( -name "*.gz" -o -name "*.bz2" -o -name "*.xz" \) -mtime +60 2>/dev/null | wc -l)
if [ "$FOUND_GZ" -gt 0 ]; then
    find /var/log -type f \( -name "*.gz" -o -name "*.bz2" -o -name "*.xz" \) -mtime +60 -delete 2>/dev/null || true
    echo -e "  ${GREEN}✓ Removed $FOUND_GZ compressed files${NC}"
    log_msg "Removed $FOUND_GZ compressed files"
else
    echo -e "  ${GREEN}✓ No old compressed files to remove${NC}"
fi
echo ""

# Clean journal logs
echo -e "${BLUE}3. Cleaning systemd journal...${NC}"
log_msg "Cleaning systemd journal older than 14 days"
if command -v journalctl &> /dev/null; then
    JOURNAL_SIZE_BEFORE=$(journalctl --disk-usage 2>/dev/null | awk '{print $7}' || echo "0")
    sudo journalctl --vacuum-time=14d >/dev/null 2>&1 || true
    JOURNAL_SIZE_AFTER=$(journalctl --disk-usage 2>/dev/null | awk '{print $7}' || echo "0")
    echo -e "  ${GREEN}✓ Journal cleaned (was: $JOURNAL_SIZE_BEFORE, now: $JOURNAL_SIZE_AFTER)${NC}"
    log_msg "Journal cleaned: $JOURNAL_SIZE_BEFORE -> $JOURNAL_SIZE_AFTER"
else
    echo -e "  ${YELLOW}⚠ journalctl not available${NC}"
fi
echo ""

# Clean Docker
if command -v docker &> /dev/null; then
    echo -e "${BLUE}4. Cleaning Docker resources...${NC}"
    log_msg "Starting Docker cleanup"
    
    # Remove stopped containers
    STOPPED=$(run_sudo docker ps -aq -f status=exited 2>/dev/null | wc -l)
    if [ "$STOPPED" -gt 0 ]; then
        run_sudo docker rm $(run_sudo docker ps -aq -f status=exited) >/dev/null 2>&1 || true
        echo -e "  ${GREEN}✓ Removed $STOPPED stopped containers${NC}"
        log_msg "Removed $STOPPED stopped containers"
    fi
    
    # Remove dangling images
    DANGLING=$(run_sudo docker images -f "dangling=true" -q 2>/dev/null | wc -l)
    if [ "$DANGLING" -gt 0 ]; then
        run_sudo docker rmi $(run_sudo docker images -f "dangling=true" -q) >/dev/null 2>&1 || true
        echo -e "  ${GREEN}✓ Removed $DANGLING dangling images${NC}"
        log_msg "Removed $DANGLING dangling images"
    fi
    
    # Prune everything older than 30 days
    echo -e "  ${BLUE}Pruning Docker resources older than 30 days...${NC}"
    run_sudo docker system prune -af --filter "until=720h" >/dev/null 2>&1 || true
    
    # Clean build cache
    run_sudo docker builder prune -af --filter "until=720h" >/dev/null 2>&1 || true
    
    echo -e "  ${GREEN}✓ Docker cleanup complete${NC}"
    log_msg "Docker cleanup complete"
    echo ""
fi

# Clean package manager cache
echo -e "${BLUE}5. Cleaning package manager cache...${NC}"
log_msg "Cleaning package manager cache"
if command -v apt-get &> /dev/null; then
    sudo apt-get autoremove -y >/dev/null 2>&1 || true
    sudo apt-get autoclean -y >/dev/null 2>&1 || true
    echo -e "  ${GREEN}✓ APT cache cleaned${NC}"
    log_msg "APT cache cleaned"
elif command -v yum &> /dev/null; then
    sudo yum clean all >/dev/null 2>&1 || true
    echo -e "  ${GREEN}✓ YUM cache cleaned${NC}"
    log_msg "YUM cache cleaned"
elif command -v dnf &> /dev/null; then
    sudo dnf clean all >/dev/null 2>&1 || true
    echo -e "  ${GREEN}✓ DNF cache cleaned${NC}"
    log_msg "DNF cache cleaned"
fi
echo ""

# Clean temporary files
echo -e "${BLUE}6. Cleaning temporary files...${NC}"
log_msg "Cleaning temporary files"
sudo find /tmp -type f -atime +7 -delete 2>/dev/null || true
sudo find /var/tmp -type f -atime +10 -delete 2>/dev/null || true
echo -e "  ${GREEN}✓ Temporary files cleaned${NC}"
log_msg "Temporary files cleaned"
echo ""

# Clean old maintenance logs (keep last 30 days)
echo -e "${BLUE}7. Rotating maintenance logs...${NC}"
find /opt/system/maintenance/logs -name "cleanup_*.log" -mtime +30 -delete 2>/dev/null || true
echo -e "  ${GREEN}✓ Old maintenance logs removed${NC}"
log_msg "Maintenance logs rotated"
echo ""

# Disk space after
echo -e "${YELLOW}Disk space after cleanup:${NC}"
df -h / | grep -v Filesystem
AFTER=$(df / | tail -1 | awk '{print $3}')
FREED=$((BEFORE - AFTER))
FREED_MB=$((FREED / 1024))
log_msg "Disk used after: $AFTER KB"
log_msg "Space freed: ${FREED_MB} MB"
echo ""

if [ $FREED -gt 0 ]; then
    echo -e "${GREEN}✅ Cleanup complete! Freed: ${FREED_MB} MB${NC}"
else
    echo -e "${GREEN}✅ Cleanup complete! No significant space freed${NC}"
fi

log_msg "Cleanup completed successfully"
echo -e "${BLUE}Log saved: $LOG_FILE${NC}"
EOFCLEANUP

run_sudo chmod +x /usr/local/bin/cleanup-logs
log_success "Cleanup script created"

# Create disk usage report script
cat > /usr/local/bin/disk-report << 'EOFREPORT'
#!/bin/bash

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}  Disk Usage Report - $(date)${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""

echo -e "${YELLOW}Filesystem Usage:${NC}"
df -h | grep -v tmpfs | grep -v udev
echo ""

echo -e "${YELLOW}Largest directories in /var/log:${NC}"
sudo du -sh /var/log/* 2>/dev/null | sort -rh | head -10
echo ""

if command -v docker &> /dev/null; then
    echo -e "${YELLOW}Docker disk usage:${NC}"
    sudo docker system df
    echo ""
fi

echo -e "${YELLOW}Journal size:${NC}"
journalctl --disk-usage 2>/dev/null || echo "journalctl not available"
EOFREPORT

run_sudo chmod +x /usr/local/bin/disk-report
log_success "Disk report script created"
echo ""

# Setup automatic execution
log_step "Step 3: Setting up automatic execution"
if command -v crontab &> /dev/null; then
    # Add weekly cleanup
    CRON_CMD="0 3 * * 0 /usr/local/bin/cleanup-logs >> /opt/system/maintenance/logs/cron.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "cleanup-logs"; echo "$CRON_CMD") | crontab -
    log_success "Weekly cleanup scheduled (Sundays at 3:00 AM)"
else
    log_warn "Crontab not available - automatic cleanup not configured"
fi
echo ""

# Display installation summary
log_success "═══════════════════════════════════════════"
log_success "  Log Maintenance Installation Complete!"
log_success "═══════════════════════════════════════════"
echo ""

log_info "🛠️ Maintenance scripts:"
echo "  Cleanup:         sudo cleanup-logs"
echo "  Disk report:     sudo disk-report"
echo ""

log_info "📁 Logs location:"
echo "  Directory: /opt/system/maintenance/logs/"
echo "  Pattern:   cleanup_YYYYMMDD.log"
echo ""

log_info "⏰ Automatic execution:"
echo "  Schedule: Every Sunday at 3:00 AM"
echo "  Cron log: /opt/system/maintenance/logs/cron.log"
echo "  View schedule: crontab -l | grep cleanup-logs"
echo ""

log_info "🧹 What gets cleaned:"
echo "  • System logs older than 30 days"
echo "  • Compressed logs older than 60 days"
echo "  • Systemd journal older than 14 days"
echo "  • Docker stopped containers"
echo "  • Docker dangling images"
echo "  • Docker resources older than 30 days"
echo "  • Package manager cache"
echo "  • Temporary files older than 7-10 days"
echo ""

log_warn "⚠️  Important notes:"
echo "  • First run may free significant space"
echo "  • Docker cleanup affects all stopped containers"
echo "  • Review logs before enabling auto-cleanup"
echo "  • Maintenance logs kept for 30 days"
echo "  • Always backup important data before cleanup"
echo ""

log_info "💡 Usage examples:"
echo "  # Check disk usage:"
echo "  sudo disk-report"
echo ""
echo "  # Run cleanup manually:"
echo "  sudo cleanup-logs"
echo ""
echo "  # View cleanup history:"
echo "  ls -lh /opt/system/maintenance/logs/"
echo ""
echo "  # Check last cleanup:"
echo "  tail -20 /opt/system/maintenance/logs/cleanup_*.log | tail -20"
echo ""


