#!/bin/bash

# ==============================================================================
# SHARED UTILITIES LIBRARY
# Common functions for logging, sudo handling, OS detection, and system operations
# ==============================================================================

set -euo pipefail

# --- COLORS FOR LOGGING ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# --- AUDIT LOGGING ---
AUDIT_LOG="${HOME}/.vps-secrets/.audit.log"

# Initialize audit log
init_audit_log() {
    local secrets_dir="${HOME}/.vps-secrets"
    
    if [ ! -d "$secrets_dir" ]; then
        mkdir -p "$secrets_dir"
        chmod 700 "$secrets_dir"
    fi
    
    if [ ! -f "$AUDIT_LOG" ]; then
        touch "$AUDIT_LOG"
        chmod 600 "$AUDIT_LOG"
    fi
}

# Write audit log entry
# Args: $1 = action, $2 = app_name, $3 = details (optional), $4 = result (SUCCESS/FAILED)
audit_log() {
    local action=$1
    local app_name=${2:-"system"}
    local details=${3:-""}
    local result=${4:-"SUCCESS"}
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local user=${SUDO_USER:-$(whoami)}
    
    init_audit_log
    
    if [ -n "$details" ]; then
        echo "[$timestamp] $action $app_name by $user - $details - $result" >> "$AUDIT_LOG"
    else
        echo "[$timestamp] $action $app_name by $user - $result" >> "$AUDIT_LOG"
    fi
}

# --- LOGGING FUNCTIONS ---
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_step() {
    echo -e "${BLUE}>>> $1${NC}"
}

log_debug() {
    if [ "${DEBUG:-0}" = "1" ]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

# --- USER CONFIRMATION ---
# Prompt user for confirmation
# Set FORCE_YES=1 environment variable to skip all confirmations
confirm_action() {
    local prompt=${1:-"Continue?"}
    
    # Check if we're in automation mode
    if [ "${FORCE_YES:-0}" = "1" ] || [ "${CI:-}" = "true" ]; then
        log_info "$prompt [AUTO-YES]"
        return 0
    fi
    
    # Interactive mode (default)
    echo -ne "${YELLOW}$prompt (y/N):${NC} "
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# --- SERVICE MANAGEMENT ---
# Ensure service is running, start if needed
# Args: $1 = service_name, $2 = friendly_name (optional)
ensure_service_running() {
    local service_name=$1
    local friendly_name=${2:-$service_name}
    
    if run_sudo systemctl is-active --quiet "$service_name" 2>/dev/null; then
        log_debug "$friendly_name is already running"
        return 0
    fi
    
    log_info "$friendly_name is not running, starting it..."
    if run_sudo systemctl start "$service_name" 2>/dev/null; then
        run_sudo systemctl enable "$service_name" 2>/dev/null || true
        log_success "$friendly_name started"
        sleep 2  # Wait for service to be ready
        return 0
    else
        log_error "Failed to start $friendly_name"
        return 1
    fi
}

# Check if service exists
service_exists() {
    local service_name=$1
    systemctl list-unit-files "$service_name.service" &>/dev/null
}

# --- SUDO WRAPPER ---
# Executes commands with root privileges
# Priority: 1) User is root, 2) SUDO_PASS env var, 3) Interactive/passwordless sudo
run_sudo() {
    # If we are root, run directly
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
        return $?
    fi
    
    # Special case: docker commands when user is in docker group
    # Check if first argument is 'docker' and user has docker group access
    if [ "$1" = "docker" ]; then
        # Check if user is in docker group (or if we just added them)
        if groups 2>/dev/null | grep -q docker || [ "${DOCKER_GROUP_ACTIVATED:-0}" = "1" ]; then
            # Try running docker without sudo first
            if "$@" 2>/dev/null; then
                return $?
            fi
            # If it fails, fall through to sudo method below
        fi
    fi

    # If SUDO_PASS is provided (automation)
    if [ -n "${SUDO_PASS:-}" ]; then
        echo "$SUDO_PASS" | sudo -S -p "" "$@" 2>/dev/null
        return $?
    fi

    # Try passwordless sudo or interactive sudo
    if sudo -n true 2>/dev/null; then
        sudo "$@"
    else
        if [ -t 0 ]; then
            sudo "$@"
        else
            log_error "Root privileges required. Please set SUDO_PASS or run as root."
            exit 1
        fi
    fi
}

# --- OS DETECTION ---
# Sets global variables: OS_NAME, OS_VERSION, PACKAGE_MANAGER
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME=$ID
        OS_VERSION=$VERSION_ID
    else
        log_error "Cannot detect OS. /etc/os-release file is missing."
        exit 1
    fi

    case "$OS_NAME" in
        ubuntu|debian|pop|linuxmint|kali)
            PACKAGE_MANAGER="apt"
            ;;
        centos|rhel|fedora|almalinux|rocky|ol)
            PACKAGE_MANAGER="yum"
            ;;
        *)
            if [[ "${ID_LIKE:-}" == *"debian"* ]]; then
                PACKAGE_MANAGER="apt"
            elif [[ "${ID_LIKE:-}" == *"rhel"* ]] || [[ "${ID_LIKE:-}" == *"fedora"* ]]; then
                PACKAGE_MANAGER="yum"
            else
                log_warn "Unknown OS ($OS_NAME). Defaulting to 'apt'."
                PACKAGE_MANAGER="apt"
            fi
            ;;
    esac

    log_debug "Detected OS: $OS_NAME $OS_VERSION | Package Manager: $PACKAGE_MANAGER"
}

# --- FIREWALL MANAGER ---
# Automatically detects and configures UFW or Firewalld
open_port() {
    local port=$1
    local comment=$2
    local proto=${3:-tcp}

    if [ -z "$port" ]; then
        log_error "open_port: Port number required"
        return 1
    fi

    log_info "Opening firewall port: $port/$proto ($comment)"

    # Check for UFW
    if command -v ufw >/dev/null 2>&1; then
        if run_sudo ufw status 2>/dev/null | grep -q "Status: active"; then
            run_sudo ufw allow "$port/$proto" comment "$comment" 2>/dev/null
            log_info "Port opened in UFW"
            return 0
        fi
    fi

    # Check for Firewalld
    if command -v firewall-cmd >/dev/null 2>&1; then
        if systemctl is-active --quiet firewalld 2>/dev/null; then
            run_sudo firewall-cmd --permanent --add-port="$port/$proto" >/dev/null 2>&1
            run_sudo firewall-cmd --reload >/dev/null 2>&1
            log_info "Port opened in Firewalld"
            return 0
        fi
    fi

    log_warn "No active firewall detected. Ensure port $port is accessible."
}

# --- PACKAGE INSTALLATION ---
# Install package if not already present
install_package() {
    local package=$1
    
    if command -v "$package" &> /dev/null; then
        log_debug "Package already installed: $package"
        return 0
    fi
    
    log_info "Installing package: $package"
    detect_os
    
    case "$PACKAGE_MANAGER" in
        apt)
            run_sudo apt-get update -qq
            run_sudo apt-get install -y "$package"
            ;;
        yum)
            run_sudo yum install -y "$package"
            ;;
        *)
            log_error "Unsupported package manager: $PACKAGE_MANAGER"
            return 1
            ;;
    esac
}

# --- DEPENDENCY CHECKER ---
# Check if a dependency (app) is installed
# Args: $1 = app category/name (e.g., "infrastructure/docker-engine")
require_dependency() {
    local dep_path=$1
    local app_name=$(basename "$dep_path")
    
    log_info "Checking dependency: $app_name"
    
    # Basic checks for common dependencies
    case "$app_name" in
        docker-engine|docker)
            if ! command -v docker &> /dev/null; then
                log_error "Docker not installed. Please install Docker first."
                log_info "Run: Select Infrastructure > Docker Engine from main menu"
                return 1
            fi
            if ! docker info &> /dev/null; then
                log_error "Docker is installed but not running"
                return 1
            fi
            log_success "Docker is available"
            return 0
            ;;
        postgres|postgresql)
            if ! docker ps --format '{{.Names}}' | grep -q "postgres"; then
                log_error "PostgreSQL container not running"
                log_info "Run: Select Databases > PostgreSQL from main menu"
                return 1
            fi
            log_success "PostgreSQL is available"
            return 0
            ;;
        nginx)
            if ! command -v nginx &> /dev/null && ! docker ps --format '{{.Names}}' | grep -q "nginx"; then
                log_error "Nginx not installed"
                return 1
            fi
            log_success "Nginx is available"
            return 0
            ;;
        *)
            log_warn "Unknown dependency: $app_name (skipping check)"
            return 0
            ;;
    esac
}

# --- SYSTEM CHECKS ---
# Check system requirements
check_system_requirements() {
    log_info "Checking system requirements..."
    
    # Check if running on Linux
    if [[ "$(uname)" != "Linux" ]]; then
        log_error "This script requires Linux"
        return 1
    fi
    
    # Check required commands
    local required_commands=("curl" "wget" "tar" "grep" "sed" "awk")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_warn "Required command not found: $cmd"
            install_package "$cmd"
        fi
    done
    
    log_success "System requirements check passed"
    return 0
}

# --- DIRECTORY MANAGEMENT ---
# Create directory with proper permissions
create_app_directory() {
    local dir_path=$1
    local permissions=${2:-755}
    
    if [ -d "$dir_path" ]; then
        log_debug "Directory already exists: $dir_path"
        return 0
    fi
    
    log_info "Creating directory: $dir_path"
    run_sudo mkdir -p "$dir_path"
    run_sudo chmod "$permissions" "$dir_path"
    
    return 0
}

# --- FILE OPERATIONS ---
# Backup a file before modification
backup_file() {
    local file_path=$1
    
    if [ ! -f "$file_path" ]; then
        log_warn "File not found for backup: $file_path"
        return 1
    fi
    
    local backup_path="${file_path}.backup_$(date +%Y%m%d_%H%M%S)"
    run_sudo cp "$file_path" "$backup_path"
    log_info "File backed up to: $backup_path"
}

# --- SERVICE MANAGEMENT ---
# Enable and start a systemd service
enable_service() {
    local service_name=$1
    
    log_info "Enabling service: $service_name"
    run_sudo systemctl enable "$service_name" 2>/dev/null
    run_sudo systemctl start "$service_name" 2>/dev/null
    
    if systemctl is-active --quiet "$service_name"; then
        log_success "Service started: $service_name"
        return 0
    else
        log_error "Failed to start service: $service_name"
        return 1
    fi
}

# Check if service is running
check_service() {
    local service_name=$1
    
    if systemctl is-active --quiet "$service_name"; then
        return 0
    else
        return 1
    fi
}

# --- NETWORK OPERATIONS ---
# Check if a URL is reachable
check_url() {
    local url=$1
    local max_attempts=${2:-3}
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if curl -sSf -o /dev/null "$url" 2>/dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    
    return 1
}

# Get public IP address
get_public_ip() {
    local ip=$(curl -s ifconfig.me 2>/dev/null)
    if [ -z "$ip" ]; then
        ip=$(curl -s api.ipify.org 2>/dev/null)
    fi
    echo "$ip"
}

# --- ERROR HANDLING ---
# Error handler for scripts
error_exit() {
    local error_msg=$1
    local exit_code=${2:-1}
    
    log_error "$error_msg"
    exit "$exit_code"
}

# Trap errors
setup_error_trap() {
    trap 'error_exit "Script failed at line $LINENO"' ERR
}

# --- CLEANUP ---
# Cleanup temporary files
cleanup_temp_files() {
    local temp_dir="/tmp/vps-orchestrator-$$"
    
    if [ -d "$temp_dir" ]; then
        rm -rf "$temp_dir"
        log_debug "Cleaned up temporary files"
    fi
}

# Register cleanup on exit
register_cleanup() {
    trap cleanup_temp_files EXIT
}

# --- INITIALIZATION ---
# Initialize logging directory
init_logging() {
    local log_dir="${HOME}/.vps-orchestrator/logs"
    
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir"
        chmod 700 "$log_dir"
    fi
    
    export LOG_FILE="${log_dir}/orchestrator_$(date +%Y%m%d).log"
}

# Log to file (in addition to console)
log_to_file() {
    if [ -n "${LOG_FILE:-}" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
    fi
}

# --- TEMPLATE PROCESSING ---
# Replace variables in template file
# Args: $1 = template_file, $2 = output_file, $3... = KEY=VALUE pairs
process_template() {
    local template_file=$1
    local output_file=$2
    shift 2
    
    if [ ! -f "$template_file" ]; then
        log_error "Template not found: $template_file"
        return 1
    fi
    
    local temp_file=$(mktemp)
    cp "$template_file" "$temp_file"
    
    # Replace each KEY=VALUE pair
    for pair in "$@"; do
        local key="${pair%%=*}"
        local value="${pair#*=}"
        sed -i "s|{{${key}}}|${value}|g" "$temp_file"
    done
    
    mv "$temp_file" "$output_file"
    log_info "Template processed: $output_file"
}
