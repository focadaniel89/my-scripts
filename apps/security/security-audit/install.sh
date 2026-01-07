#!/bin/bash

# ==============================================================================
# SECURITY AUDIT TOOLKIT
# Automated security scanning for Docker images and system vulnerabilities
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/docker.sh"

APP_NAME="security-audit"
AUDIT_DIR="/opt/security/audit"

log_info "═══════════════════════════════════════════"
log_info "  Installing Security Audit Toolkit"
log_info "═══════════════════════════════════════════"
echo ""

# Check dependencies
log_step "Step 1: Checking dependencies"
if ! check_docker; then
    log_error "Docker is not installed"
    log_info "Please install Docker first: Infrastructure > Docker Engine"
    exit 1
fi
log_success "Docker is available"
echo ""

# Setup directories
log_step "Step 2: Setting up directories"
create_app_directory "$AUDIT_DIR"
create_app_directory "$AUDIT_DIR/reports"
create_app_directory "$AUDIT_DIR/scans"
log_success "Audit directories created"
echo ""

# Pull security tools
log_step "Step 3: Downloading security scanning tools"
log_info "Pulling Trivy (vulnerability scanner)..."
run_sudo docker pull aquasec/trivy:latest
log_success "Trivy downloaded"
echo ""

# Create comprehensive audit script
log_step "Step 4: Creating audit scripts"
cat > /usr/local/bin/security-audit << 'EOFAUDIT'
#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REPORT_DIR="/opt/security/audit/reports"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_FILE="$REPORT_DIR/audit_$TIMESTAMP.txt"

echo -e "${BLUE}════════════════════════════════════${NC}"
echo -e "${BLUE}  Security Audit - $(date)${NC}"
echo -e "${BLUE}════════════════════════════════════${NC}"
echo ""

{
    echo "Security Audit Report"
    echo "Generated: $(date)"
    echo "================================================"
    echo ""

    # Docker image scanning
    echo "1. DOCKER IMAGE VULNERABILITY SCAN"
    echo "-----------------------------------"
    IMAGES=$(run_sudo docker images --format "{{.Repository}}:{{.Tag}}" | grep -v "<none>" | head -20)
    if [ -n "$IMAGES" ]; then
        while IFS= read -r image; do
            echo "Scanning: $image"
            run_sudo docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
                aquasec/trivy image --severity HIGH,CRITICAL --no-progress "$image" 2>&1 || true
            echo ""
        done <<< "$IMAGES"
    else
        echo "No Docker images found"
    fi
    echo ""

    # Running containers check
    echo "2. RUNNING CONTAINERS"
    echo "----------------------"
    run_sudo docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>&1 || echo "Error checking containers"
    echo ""

    # System security checks
    echo "3. SYSTEM SECURITY CHECKS"
    echo "--------------------------"
    
    # Firewall status
    echo "Firewall Status:"
    if command -v ufw &> /dev/null; then
        run_sudo ufw status 2>&1 || echo "UFW not active"
    elif command -v firewall-cmd &> /dev/null; then
        run_sudo firewall-cmd --state 2>&1 || echo "Firewalld not active"
    else
        echo "No firewall detected"
    fi
    echo ""

    # Fail2ban status
    echo "Fail2ban Status:"
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        sudo fail2ban-client status 2>&1 || echo "Error getting fail2ban status"
    else
        echo "Fail2ban not running"
    fi
    echo ""

    # Open ports
    echo "Open Ports:"
    ss -tulpn 2>&1 | grep LISTEN || netstat -tulpn 2>&1 | grep LISTEN || echo "Cannot determine open ports"
    echo ""

    # SSH configuration
    echo "SSH Security:"
    if [ -f /etc/ssh/sshd_config ]; then
        echo "PermitRootLogin: $(grep -i '^PermitRootLogin' /etc/ssh/sshd_config || echo 'default')"
        echo "PasswordAuthentication: $(grep -i '^PasswordAuthentication' /etc/ssh/sshd_config || echo 'default')"
        echo "Port: $(grep -i '^Port' /etc/ssh/sshd_config || echo 'default (22)')"
    fi
    echo ""

    # Summary
    echo "4. SUMMARY"
    echo "----------"
    echo "Report saved to: $REPORT_FILE"
    echo "Scan completed: $(date)"
    
} | tee "$REPORT_FILE"

echo ""
echo -e "${GREEN}✅ Security audit complete!${NC}"
echo -e "${BLUE}Report: $REPORT_FILE${NC}"
EOFAUDIT

run_sudo chmod +x /usr/local/bin/security-audit
log_success "Main audit script created"

# Create image-only scan script
cat > /usr/local/bin/scan-docker-images << 'EOFSCAN'
#!/bin/bash
set -euo pipefail

SEVERITY="${1:-HIGH,CRITICAL}"

echo "Scanning Docker images for vulnerabilities..."
echo "Severity filter: $SEVERITY"
echo ""

IMAGES=$(run_sudo docker images --format "{{.Repository}}:{{.Tag}}" | grep -v "<none>")

if [ -z "$IMAGES" ]; then
    echo "No Docker images found"
    exit 0
fi

while IFS= read -r image; do
    echo "=================================="
    echo "Scanning: $image"
    echo "=================================="
    run_sudo docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        aquasec/trivy image \
        --severity "$SEVERITY" \
        --no-progress \
        "$image"
    echo ""
done <<< "$IMAGES"

echo "Scan complete!"
EOFSCAN

run_sudo chmod +x /usr/local/bin/scan-docker-images
log_success "Docker image scanner created"
echo ""

# Setup automatic scanning
log_step "Step 5: Setting up automatic scanning"
if command -v crontab &> /dev/null; then
    # Add weekly audit cron job
    CRON_CMD="0 2 * * 0 /usr/local/bin/security-audit >> /opt/security/audit/scans/cron.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "security-audit"; echo "$CRON_CMD") | crontab -
    log_success "Weekly audit scheduled (Sundays at 2 AM)"
else
    log_warn "Crontab not available - automatic scanning not configured"
fi
echo ""

# Display installation summary
log_success "═══════════════════════════════════════════"
log_success "  Security Audit Installation Complete!"
log_success "═══════════════════════════════════════════"
echo ""

log_info "📁 Reports location:"
echo "  Directory: $AUDIT_DIR/reports/"
echo "  Cron logs: $AUDIT_DIR/scans/cron.log"
echo ""

log_info "🔍 Audit commands:"
echo "  Full audit:           sudo security-audit"
echo "  Scan Docker images:   sudo scan-docker-images"
echo "  Scan specific image:  docker run --rm aquasec/trivy image IMAGE_NAME"
echo ""

log_info "📄 Severity filters:"
echo "  All:              sudo scan-docker-images ALL"
echo "  High + Critical:  sudo scan-docker-images HIGH,CRITICAL (default)"
echo "  Critical only:    sudo scan-docker-images CRITICAL"
echo ""

log_info "⏰ Automatic scanning:"
echo "  Schedule: Every Sunday at 2:00 AM"
echo "  View schedule: crontab -l | grep security-audit"
echo "  Disable: crontab -e (remove security-audit line)"
echo ""

log_info "📊 What gets scanned:"
echo "  • Docker image vulnerabilities (CVEs)"
echo "  • Running containers status"
echo "  • Firewall configuration"
echo "  • Fail2ban status"
echo "  • Open network ports"
echo "  • SSH security configuration"
echo ""

log_warn "⚠️  Important notes:"
echo "  • Trivy database updates automatically on each scan"
echo "  • First scan may take longer (database download)"
echo "  • Reports contain detailed CVE information"
echo "  • Review reports regularly and patch vulnerabilities"
echo "  • Consider integrating with CI/CD pipelines"
echo ""

log_info "💡 Next steps:"
echo "  1. Run first audit: sudo security-audit"
echo "  2. Review generated report"
echo "  3. Update vulnerable images"
echo "  4. Schedule regular reviews of audit reports"
echo "  5. Consider additional tools: Lynis, OSSEC, Wazuh"
echo ""

log_info "📚 Additional resources:"
echo "  • Trivy: https://github.com/aquasecurity/trivy"
echo "  • CIS Docker Benchmark: https://www.cisecurity.org/"
echo "  • OWASP: https://owasp.org/"
echo ""


