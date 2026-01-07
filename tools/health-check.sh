#!/bin/bash

# ==============================================================================
# VPS HEALTH CHECK
# Checks status of all installed services and system resources
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"

SECRETS_DIR="${HOME}/.vps-secrets"

print_header() {
    echo "=============================================="
    echo "  VPS Health Check - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=============================================="
    echo ""
}

check_system_resources() {
    echo "[SYSTEM RESOURCES]"
    echo ""
    
    # Disk space
    echo "Disk Usage:"
    df -h / | awk 'NR==1 {print "  " $0} NR==2 {print "  " $0}'
    echo ""
    
    # Memory
    echo "Memory:"
    free -h | awk 'NR==1 {print "  " $0} NR==2 {print "  " $0}'
    echo ""
    
    # CPU Load
    echo "CPU Load:"
    echo "  $(uptime | awk -F'load average:' '{print $2}')"
    echo ""
}

check_docker_containers() {
    echo "[DOCKER CONTAINERS]"
    echo ""
    
    if ! command -v docker &> /dev/null; then
        echo "  Docker not installed"
        echo ""
        return
    fi
    
    if ! docker ps &> /dev/null; then
        echo "  Docker daemon not running"
        echo ""
        return
    fi
    
    local containers=$(docker ps -a --format "{{.Names}}")
    
    if [ -z "$containers" ]; then
        echo "  No containers found"
        echo ""
        return
    fi
    
    printf "  %-25s %-15s %-10s\n" "NAME" "STATUS" "HEALTH"
    printf "  %-25s %-15s %-10s\n" "----" "------" "------"
    
    while IFS= read -r container; do
        local status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
        local health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || echo "none")
        
        printf "  %-25s %-15s %-10s\n" "$container" "$status" "$health"
    done <<< "$containers"
    
    echo ""
}

check_native_services() {
    echo "[NATIVE SERVICES]"
    echo ""
    
    local services=("nginx" "redis-server" "fail2ban" "wg-quick@wg0")
    
    for service in "${services[@]}"; do
        if systemctl list-unit-files | grep -q "^${service}"; then
            local status=$(systemctl is-active "$service" 2>/dev/null || echo "inactive")
            printf "  %-25s %s\n" "$service" "$status"
        fi
    done
    
    echo ""
}

check_network_ports() {
    echo "[NETWORK PORTS]"
    echo ""
    
    if command -v ss &> /dev/null; then
        echo "  Listening ports:"
        ss -tuln | grep LISTEN | awk '{print "    " $5}' | sort -u
    elif command -v netstat &> /dev/null; then
        echo "  Listening ports:"
        netstat -tuln | grep LISTEN | awk '{print "    " $4}' | sort -u
    else
        echo "  ss/netstat not available"
    fi
    
    echo ""
}

check_credentials() {
    echo "[CREDENTIALS]"
    echo ""
    
    if [ ! -d "$SECRETS_DIR" ]; then
        echo "  Secrets directory not found"
        echo ""
        return
    fi
    
    local count=$(ls -1 "${SECRETS_DIR}"/.env_* 2>/dev/null | wc -l)
    echo "  Stored credentials: $count apps"
    
    if [ $count -gt 0 ]; then
        echo "  Applications:"
        for file in "${SECRETS_DIR}"/.env_*; do
            local app=$(basename "$file" | sed 's/^\.env_//')
            echo "    - $app"
        done
    fi
    
    echo ""
}

check_ssl_certificates() {
    echo "[SSL CERTIFICATES]"
    echo ""
    
    local certbot_dir="/etc/letsencrypt/live"
    
    # Check certbot timer status
    if systemctl list-unit-files | grep -q "certbot.timer"; then
        local timer_status=$(systemctl is-active certbot.timer 2>/dev/null || echo "inactive")
        echo "  Certbot auto-renewal: $timer_status"
        
        if [ "$timer_status" != "active" ]; then
            echo "    [WARNING] Certbot timer not active - SSL certificates will not auto-renew!"
        fi
        echo ""
    fi
    
    if [ ! -d "$certbot_dir" ]; then
        echo "  No SSL certificates found"
        echo ""
        return
    fi
    
    local domains=$(ls -1 "$certbot_dir" 2>/dev/null | grep -v README)
    
    if [ -z "$domains" ]; then
        echo "  No SSL certificates found"
        echo ""
        return
    fi
    
    printf "  %-30s %-20s %-10s\n" "DOMAIN" "EXPIRES" "STATUS"
    printf "  %-30s %-20s %-10s\n" "------" "-------" "------"
    
    while IFS= read -r domain; do
        if [ -f "${certbot_dir}/${domain}/cert.pem" ]; then
            local expiry_date=$(openssl x509 -enddate -noout -in "${certbot_dir}/${domain}/cert.pem" 2>/dev/null | cut -d= -f2 || echo "unknown")
            local expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
            local now_epoch=$(date +%s)
            local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
            
            local status="OK"
            if [ $days_left -lt 30 ]; then
                status="WARNING"
            fi
            if [ $days_left -lt 7 ]; then
                status="CRITICAL"
            fi
            
            printf "  %-30s %-20s %-10s\n" "$domain" "$expiry_date" "$status ($days_left days)"
        fi
    done <<< "$domains"
    
    echo ""
}

check_backups() {
    echo "[BACKUPS]"
    echo ""
    
    # Credentials backups
    local backup_dir="${SECRETS_DIR}/.backup"
    if [ -d "$backup_dir" ]; then
        local backup_count=$(ls -1 "$backup_dir"/*.tar.gz 2>/dev/null | wc -l)
        echo "  Credential backups: $backup_count"
        
        if [ $backup_count -gt 0 ]; then
            local latest=$(ls -t "$backup_dir"/*.tar.gz 2>/dev/null | head -1)
            if [ -n "$latest" ]; then
                local latest_date=$(stat -c %y "$latest" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
                echo "  Latest backup: $latest_date"
            fi
        fi
    else
        echo "  No credential backups found"
    fi
    
    echo ""
    
    # Database backups
    local db_backup_dir="/opt/backups"
    if [ -d "$db_backup_dir" ]; then
        local db_backup_count=$(find "$db_backup_dir" -type f -name "*.sql*" -o -name "*.dump*" 2>/dev/null | wc -l)
        echo "  Database backups: $db_backup_count"
        
        if [ $db_backup_count -gt 0 ]; then
            local latest_db=$(find "$db_backup_dir" -type f \( -name "*.sql*" -o -name "*.dump*" \) -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
            if [ -n "$latest_db" ]; then
                local latest_db_date=$(stat -c %y "$latest_db" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
                echo "  Latest DB backup: $latest_db_date"
            fi
        fi
    else
        echo "  No database backups found"
    fi
    
    echo ""
}

# Generate HTML dashboard
generate_html() {
    local output_file=${1:-"/var/www/html/status.html"}
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    cat > "$output_file" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="refresh" content="30">
    <title>VPS Status Dashboard</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #1e3c72 0%, #2a5298 100%);
            padding: 20px;
            color: #333;
        }
        .container {
            max-width: 1400px;
            margin: 0 auto;
        }
        .header {
            background: white;
            padding: 30px;
            border-radius: 12px;
            box-shadow: 0 8px 16px rgba(0,0,0,0.15);
            margin-bottom: 25px;
            text-align: center;
        }
        .header h1 {
            color: #1e3c72;
            margin-bottom: 10px;
            font-size: 32px;
        }
        .timestamp {
            color: #666;
            font-size: 14px;
        }
        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(400px, 1fr));
            gap: 25px;
            margin-bottom: 25px;
        }
        .card {
            background: white;
            padding: 25px;
            border-radius: 12px;
            box-shadow: 0 8px 16px rgba(0,0,0,0.15);
            transition: transform 0.2s, box-shadow 0.2s;
        }
        .card:hover {
            transform: translateY(-5px);
            box-shadow: 0 12px 24px rgba(0,0,0,0.2);
        }
        .card h2 {
            color: #1e3c72;
            margin-bottom: 20px;
            font-size: 22px;
            border-bottom: 3px solid #2a5298;
            padding-bottom: 10px;
            display: flex;
            align-items: center;
        }
        table {
            width: 100%;
            border-collapse: collapse;
        }
        th, td {
            text-align: left;
            padding: 12px 8px;
            border-bottom: 1px solid #eee;
        }
        th {
            background: #f8f9fa;
            font-weight: 600;
            color: #555;
            text-transform: uppercase;
            font-size: 12px;
        }
        .status-running { color: #28a745; font-weight: bold; }
        .status-stopped { color: #dc3545; font-weight: bold; }
        .status-healthy { color: #28a745; }
        .status-unhealthy { color: #dc3545; }
        .status-active { color: #28a745; font-weight: bold; }
        .status-inactive { color: #dc3545; font-weight: bold; }
        .warning { color: #ff9800; font-weight: bold; }
        .critical { color: #dc3545; font-weight: bold; }
        .ok { color: #28a745; font-weight: bold; }
        .metric {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 12px 0;
            border-bottom: 1px solid #eee;
        }
        .metric:last-child { border-bottom: none; }
        .metric-label { 
            font-weight: 600; 
            color: #555;
            flex: 0 0 40%;
        }
        .metric-value { 
            color: #333;
            flex: 1;
        }
        .progress-container {
            flex: 1;
            display: flex;
            align-items: center;
            gap: 10px;
        }
        .progress-bar {
            flex: 1;
            height: 24px;
            background: #e9ecef;
            border-radius: 12px;
            overflow: hidden;
            box-shadow: inset 0 2px 4px rgba(0,0,0,0.1);
        }
        .progress-fill {
            height: 100%;
            display: flex;
            align-items: center;
            justify-content: center;
            color: white;
            font-weight: bold;
            font-size: 12px;
            transition: width 0.5s ease;
            border-radius: 12px;
        }
        .progress-low { background: linear-gradient(135deg, #28a745 0%, #20c997 100%); }
        .progress-medium { background: linear-gradient(135deg, #ffc107 0%, #ff9800 100%); }
        .progress-high { background: linear-gradient(135deg, #dc3545 0%, #c82333 100%); }
        .footer {
            background: white;
            padding: 20px;
            border-radius: 12px;
            box-shadow: 0 8px 16px rgba(0,0,0,0.15);
            text-align: center;
            color: #666;
            font-size: 14px;
        }
        .badge {
            display: inline-block;
            padding: 4px 10px;
            border-radius: 12px;
            font-size: 12px;
            font-weight: bold;
        }
        .badge-success { background: #d4edda; color: #155724; }
        .badge-danger { background: #f8d7da; color: #721c24; }
        .badge-warning { background: #fff3cd; color: #856404; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>VPS Status Dashboard</h1>
            <div class="timestamp">Last updated: TIMESTAMP_PLACEHOLDER</div>
        </div>

        <div class="grid">
            <!-- System Resources -->
            <div class="card">
                <h2>System Resources</h2>
                SYSTEM_RESOURCES_PLACEHOLDER
            </div>

            <!-- Docker Containers -->
            <div class="card">
                <h2>Docker Containers</h2>
                DOCKER_CONTAINERS_PLACEHOLDER
            </div>

            <!-- Native Services -->
            <div class="card">
                <h2>Native Services</h2>
                NATIVE_SERVICES_PLACEHOLDER
            </div>

            <!-- SSL Certificates -->
            <div class="card">
                <h2>SSL Certificates</h2>
                SSL_CERTIFICATES_PLACEHOLDER
            </div>

            <!-- Credentials -->
            <div class="card">
                <h2>Credentials</h2>
                CREDENTIALS_PLACEHOLDER
            </div>

            <!-- Backups -->
            <div class="card">
                <h2>Backups</h2>
                BACKUPS_PLACEHOLDER
            </div>
        </div>

        <div class="footer">
            Auto-refreshes every 30 seconds | Generated by VPS Health Check
        </div>
    </div>
</body>
</html>
HTMLEOF

    # Generate system resources
    local disk_usage=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')
    local disk_total=$(df -h / | tail -1 | awk '{print $2}')
    local disk_used=$(df -h / | tail -1 | awk '{print $3}')
    
    local mem_total=$(free -h | awk '/^Mem:/{print $2}')
    local mem_used=$(free -h | awk '/^Mem:/{print $3}')
    local mem_percent=$(free | awk '/^Mem:/{printf "%.0f", $3/$2 * 100}')
    
    local cpu_load=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
    
    # Determine progress bar colors based on usage
    local disk_color="progress-low"
    [ $disk_usage -gt 70 ] && disk_color="progress-medium"
    [ $disk_usage -gt 90 ] && disk_color="progress-high"
    
    local mem_color="progress-low"
    [ $mem_percent -gt 70 ] && mem_color="progress-medium"
    [ $mem_percent -gt 90 ] && mem_color="progress-high"
    
    local system_html="<div class='metric'><span class='metric-label'>Disk Usage</span><div class='progress-container'><div class='progress-bar'><div class='progress-fill $disk_color' style='width: ${disk_usage}%'>${disk_usage}%</div></div><span>${disk_used} / ${disk_total}</span></div></div>"
    system_html+="<div class='metric'><span class='metric-label'>Memory</span><div class='progress-container'><div class='progress-bar'><div class='progress-fill $mem_color' style='width: ${mem_percent}%'>${mem_percent}%</div></div><span>${mem_used} / ${mem_total}</span></div></div>"
    system_html+="<div class='metric'><span class='metric-label'>CPU Load</span><span class='metric-value'>${cpu_load}</span></div>"
    
    # Generate docker containers
    local docker_html="<table><tr><th>Name</th><th>Status</th><th>Health</th></tr>"
    
    if docker ps -a &> /dev/null; then
        while IFS= read -r container; do
            local status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
            local health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || echo "none")
            
            local status_class="status-stopped"
            [ "$status" = "running" ] && status_class="status-running"
            
            local health_class=""
            [ "$health" = "healthy" ] && health_class="status-healthy"
            [ "$health" = "unhealthy" ] && health_class="status-unhealthy"
            
            docker_html+="<tr><td>$container</td><td class='$status_class'>$status</td><td class='$health_class'>$health</td></tr>"
        done < <(docker ps -a --format '{{.Names}}' 2>/dev/null || echo "")
    fi
    docker_html+="</table>"
    
    # Generate native services
    local services_html="<table><tr><th>Service</th><th>Status</th></tr>"
    for service in nginx redis-server fail2ban; do
        if systemctl list-unit-files | grep -q "^${service}"; then
            local status=$(systemctl is-active "$service" 2>/dev/null || echo "inactive")
            local status_class="status-inactive"
            [ "$status" = "active" ] && status_class="status-active"
            services_html+="<tr><td>$service</td><td class='$status_class'>$status</td></tr>"
        fi
    done
    services_html+="</table>"
    
    # Generate SSL certificates
    local ssl_html="<table><tr><th>Domain</th><th>Days Left</th><th>Status</th></tr>"
    local certbot_dir="/etc/letsencrypt/live"
    
    if [ -d "$certbot_dir" ]; then
        while IFS= read -r domain; do
            if [ -f "${certbot_dir}/${domain}/cert.pem" ]; then
                local expiry_date=$(openssl x509 -enddate -noout -in "${certbot_dir}/${domain}/cert.pem" 2>/dev/null | cut -d= -f2)
                local expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
                local now_epoch=$(date +%s)
                local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
                
                local status_class=""
                local status_text="OK"
                local status_badge="badge-success"
                if [ $days_left -lt 30 ]; then
                    status_class="warning"
                    status_text="WARNING"
                    status_badge="badge-warning"
                fi
                if [ $days_left -lt 7 ]; then
                    status_class="critical"
                    status_text="CRITICAL"
                    status_badge="badge-danger"
                fi
                
                ssl_html+="<tr><td>$domain</td><td>$days_left days</td><td><span class='badge $status_badge'>$status_text</span></td></tr>"
            fi
        done < <(ls -1 "$certbot_dir" 2>/dev/null | grep -v README || echo "")
    fi
    ssl_html+="</table>"
    
    # Generate credentials
    local cred_count=$(ls -1 "${SECRETS_DIR}"/.env_* 2>/dev/null | wc -l)
    local cred_html="<div class='metric'><span class='metric-label'>Stored credentials:</span><span class='metric-value'>$cred_count apps</span></div>"
    
    # Generate backups
    local backup_dir="${SECRETS_DIR}/.backup"
    local cred_backup_count=$(ls -1 "$backup_dir"/*.tar.gz 2>/dev/null | wc -l)
    local db_backup_count=$(find /opt/backups -type f \( -name "*.sql*" -o -name "*.dump*" \) 2>/dev/null | wc -l)
    
    local backup_html="<div class='metric'><span class='metric-label'>Credential backups:</span><span class='metric-value'>$cred_backup_count</span></div>"
    backup_html+="<div class='metric'><span class='metric-label'>Database backups:</span><span class='metric-value'>$db_backup_count</span></div>"
    
    # Replace placeholders
    sed -i "s|TIMESTAMP_PLACEHOLDER|$timestamp|g" "$output_file"
    sed -i "s|SYSTEM_RESOURCES_PLACEHOLDER|$system_html|g" "$output_file"
    sed -i "s|DOCKER_CONTAINERS_PLACEHOLDER|$docker_html|g" "$output_file"
    sed -i "s|NATIVE_SERVICES_PLACEHOLDER|$services_html|g" "$output_file"
    sed -i "s|SSL_CERTIFICATES_PLACEHOLDER|$ssl_html|g" "$output_file"
    sed -i "s|CREDENTIALS_PLACEHOLDER|$cred_html|g" "$output_file"
    sed -i "s|BACKUPS_PLACEHOLDER|$backup_html|g" "$output_file"
    
    log_success "HTML dashboard generated: $output_file"
}

# Main execution
main() {
    local mode=${1:-"terminal"}
    
    if [ "$mode" = "--html" ]; then
        local output=${2:-"/var/www/html/status.html"}
        generate_html "$output"
    else
        print_header
        check_system_resources
        check_docker_containers
        check_native_services
        check_network_ports
        check_credentials
        check_ssl_certificates
        check_backups
        
        echo "=============================================="
        echo "  Health check completed"
        echo "=============================================="
    fi
}

main "$@"
