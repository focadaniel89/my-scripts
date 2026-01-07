#!/bin/bash

# ==============================================================================
# SECRET MANAGEMENT LIBRARY
# Manages secure storage, generation, and retrieval of application credentials
# ==============================================================================

set -euo pipefail

# Source required libraries
SECRETS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SECRETS_LIB_DIR}/utils.sh" ]; then
    source "${SECRETS_LIB_DIR}/utils.sh"
fi

readonly SECRETS_DIR="${HOME}/.vps-secrets"
readonly BACKUP_DIR="${SECRETS_DIR}/.backup"
readonly INDEX_FILE="${SECRETS_DIR}/.secrets_index.json"

# Initialize secrets directory structure
init_secrets_dir() {
    if [ ! -d "$SECRETS_DIR" ]; then
        mkdir -p "$SECRETS_DIR"
        chmod 700 "$SECRETS_DIR"
        log_info "Created secrets directory: $SECRETS_DIR"
    fi
    
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
        chmod 700 "$BACKUP_DIR"
    fi
    
    if [ ! -f "$INDEX_FILE" ]; then
        echo '{}' > "$INDEX_FILE"
        chmod 600 "$INDEX_FILE"
    fi
}

# Generate a cryptographically secure password
# Args: $1 = length (default: 32), $2 = character set (default: alphanumeric + special)
generate_secure_password() {
    local length=${1:-32}
    local charset=${2:-"alphanumeric_special"}
    
    case "$charset" in
        alphanumeric)
            openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "$length"
            ;;
        alphanumeric_special)
            openssl rand -base64 48 | tr -dc 'a-zA-Z0-9!@#$%^&*()-_=+' | head -c "$length"
            ;;
        numeric)
            openssl rand -base64 48 | tr -dc '0-9' | head -c "$length"
            ;;
        *)
            openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "$length"
            ;;
    esac
}

# Generate a secure database name (alphanumeric only)
generate_db_name() {
    local prefix=${1:-"db"}
    echo "${prefix}_$(openssl rand -hex 4)"
}

# Save a secret for an application
# Args: $1 = app_name, $2 = var_name, $3 = value
save_secret() {
    local app_name=$1
    local var_name=$2
    local value=$3
    
    init_secrets_dir
    
    local env_file="${SECRETS_DIR}/.env_${app_name}"
    
    # Check if variable already exists in file
    if [ -f "$env_file" ] && grep -q "^${var_name}=" "$env_file"; then
        # Update existing variable (no quotes for cleaner debugging)
        sed -i "s|^${var_name}=.*|${var_name}=${value}|" "$env_file"
    else
        # Append new variable (no quotes for cleaner debugging)
        echo "${var_name}=${value}" >> "$env_file"
    fi
    
    chmod 600 "$env_file"
    
    # Update index
    update_secrets_index "$app_name" "$var_name"
    
    log_info "Secret saved: ${app_name}.${var_name}"
}

# Load secrets for an application into environment
# Args: $1 = app_name
load_secrets() {
    local app_name=$1
    local env_file="${SECRETS_DIR}/.env_${app_name}"
    
    if [ -f "$env_file" ]; then
        source "$env_file"
        log_info "Loaded secrets for: $app_name"
        return 0
    else
        log_warn "No secrets found for: $app_name"
        return 1
    fi
}

# Check if an application has credentials stored
# Args: $1 = app_name
has_credentials() {
    local app_name=$1
    local env_file="${SECRETS_DIR}/.env_${app_name}"
    
    [ -f "$env_file" ] && [ -s "$env_file" ]
}

# Get a specific secret value
# Args: $1 = app_name, $2 = var_name
get_secret() {
    local app_name=$1
    local var_name=$2
    local env_file="${SECRETS_DIR}/.env_${app_name}"
    
    if [ -f "$env_file" ]; then
        grep "^${var_name}=" "$env_file" | cut -d'=' -f2- | tr -d "'"
    fi
}

# Backup all credentials to timestamped archive
backup_all_secrets() {
    init_secrets_dir
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/credentials_${timestamp}.tar.gz"
    
    # Check if there are credentials to backup
    local cred_files=$(ls -1 "${SECRETS_DIR}"/.env_* 2>/dev/null)
    
    if [ -z "$cred_files" ]; then
        log_warn "No credentials found to backup"
        return 1
    fi
    
    # Create backup
    tar -czf "$backup_file" -C "$SECRETS_DIR" \
        $(ls -A "$SECRETS_DIR" | grep "^\.env_") \
        2>/dev/null
    
    if [ $? -eq 0 ]; then
        chmod 600 "$backup_file"
        log_success "Credentials backed up to: $backup_file"
        return 0
    else
        log_error "Backup failed"
        return 1
    fi
}

# Restore credentials from backup
# Args: $1 = backup_file
restore_secrets_from_backup() {
    local backup_file=$1
    
    if [ ! -f "$backup_file" ]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi
    
    tar -xzf "$backup_file" -C "$SECRETS_DIR"
    
    if [ $? -eq 0 ]; then
        log_success "Credentials restored from: $backup_file"
        return 0
    else
        log_error "Restore failed"
        return 1
    fi
}

# Display connection information for an application
# Args: $1 = app_name
display_connection_info() {
    local app_name=$1
    local env_file="${SECRETS_DIR}/.env_${app_name}"
    
    if [ ! -f "$env_file" ]; then
        log_error "No credentials found for: $app_name"
        return 1
    fi
    
    echo ""
    echo "${GREEN}═══════════════════════════════════════════${NC}"
    echo "${GREEN}  Connection Information: ${app_name}${NC}"
    echo "${GREEN}═══════════════════════════════════════════${NC}"
    
    # Load and display (masked for security)
    while IFS='=' read -r key value; do
        if [ -n "$key" ] && [[ ! "$key" =~ ^# ]]; then
            # Show first 4 and last 4 characters, mask the rest
            local clean_value=$(echo "$value" | tr -d "'\"")
            local value_length=${#clean_value}
            
            if [ "$value_length" -gt 8 ]; then
                local mask_len=$((value_length - 8))
                local masked="${clean_value:0:4}$(printf '%*s' "$mask_len" '' | tr ' ' '*')${clean_value: -4}"
            else
                local masked="****"
            fi
            
            echo "  ${BLUE}${key}${NC}: ${masked}"
        fi
    done < "$env_file"
    
    echo ""
    echo "  ${YELLOW}Full credentials:${NC} $env_file"
    echo "${GREEN}═══════════════════════════════════════════${NC}"
    echo ""
}

# Update the secrets index (JSON format)
# Args: $1 = app_name, $2 = var_name
update_secrets_index() {
    local app_name=$1
    local var_name=$2
    
    if ! command -v jq &> /dev/null; then
        # Skip if jq not available
        return 0
    fi
    
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Update or create entry
    if [ -f "$INDEX_FILE" ]; then
        local temp_file=$(mktemp)
        jq --arg app "$app_name" \
           --arg var "$var_name" \
           --arg ts "$timestamp" \
           '.[$app] += {($var): {"updated": $ts}}' \
           "$INDEX_FILE" > "$temp_file" 2>/dev/null || echo '{}' > "$temp_file"
        mv "$temp_file" "$INDEX_FILE"
        chmod 600 "$INDEX_FILE"
    fi
}

# List all applications with stored secrets
list_all_secrets() {
    init_secrets_dir
    
    echo ""
    echo "${GREEN}═══════════════════════════════════════════${NC}"
    echo "${GREEN}  Stored Application Credentials${NC}"
    echo "${GREEN}═══════════════════════════════════════════${NC}"
    echo ""
    
    local count=0
    for env_file in "${SECRETS_DIR}"/.env_*; do
        if [ -f "$env_file" ]; then
            local app_name=$(basename "$env_file" | sed 's/^\.env_//')
            local var_count=$(grep -c "^[^#]" "$env_file" 2>/dev/null || echo "0")
            local modified=$(stat -c %y "$env_file" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
            
            echo "  ${BLUE}[$((++count))]${NC} ${YELLOW}${app_name}${NC}"
            echo "      Variables: ${var_count}"
            echo "      Modified: ${modified}"
            echo "      Location: ${env_file}"
            echo ""
        fi
    done
    
    if [ "$count" -eq 0 ]; then
        echo "  ${YELLOW}No credentials stored yet.${NC}"
        echo ""
    fi
    
    echo "${GREEN}═══════════════════════════════════════════${NC}"
    echo ""
}

# Backup all secrets
backup_secrets() {
    init_secrets_dir
    
    local backup_name="secrets_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    local backup_path="${BACKUP_DIR}/${backup_name}"
    
    log_info "Creating secrets backup..."
    
    tar -czf "$backup_path" -C "$SECRETS_DIR" $(ls -A "$SECRETS_DIR" | grep -E "^\.env_") 2>/dev/null
    
    if [ $? -eq 0 ]; then
        chmod 600 "$backup_path"
        log_success "Backup created: $backup_path"
        
        # Keep only last 10 backups
        local backup_count=$(ls -1 "$BACKUP_DIR"/secrets_backup_*.tar.gz 2>/dev/null | wc -l)
        if [ "$backup_count" -gt 10 ]; then
            ls -1t "$BACKUP_DIR"/secrets_backup_*.tar.gz | tail -n +11 | xargs rm -f
            log_info "Cleaned old backups (keeping last 10)"
        fi
    else
        log_error "Backup failed"
        return 1
    fi
}

# Regenerate secrets for an application
# Args: $1 = app_name
regenerate_secrets() {
    local app_name=$1
    local env_file="${SECRETS_DIR}/.env_${app_name}"
    
    if [ ! -f "$env_file" ]; then
        log_error "No secrets found for: $app_name"
        return 1
    fi
    
    echo ""
    echo "${YELLOW}WARNING: This will regenerate ALL secrets for ${app_name}${NC}"
    echo "${YELLOW}The application will need to be reconfigured with new credentials.${NC}"
    echo ""
    read -p "Are you sure? (yes/no): " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        log_info "Operation cancelled"
        return 0
    fi
    
    # Backup current secrets
    local backup_file="${env_file}.backup_$(date +%Y%m%d_%H%M%S)"
    cp "$env_file" "$backup_file"
    chmod 600 "$backup_file"
    log_info "Current secrets backed up to: $backup_file"
    
    # Regenerate each variable
    while IFS='=' read -r key value; do
        if [ -n "$key" ] && [[ ! "$key" =~ ^# ]]; then
            local new_value=$(generate_secure_password)
            save_secret "$app_name" "$key" "$new_value"
        fi
    done < "$env_file"
    
    log_success "Secrets regenerated for: $app_name"
    echo ""
    echo "${YELLOW}Remember to update the application configuration!${NC}"
    echo ""
}

# Delete secrets for an application
# Args: $1 = app_name
delete_secrets() {
    local app_name=$1
    local env_file="${SECRETS_DIR}/.env_${app_name}"
    
    if [ ! -f "$env_file" ]; then
        log_error "No secrets found for: $app_name"
        return 1
    fi
    
    echo ""
    echo "${RED}WARNING: This will permanently delete secrets for ${app_name}${NC}"
    echo ""
    read -p "Are you sure? (yes/no): " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        log_info "Operation cancelled"
        return 0
    fi
    
    # Backup before deletion
    local backup_file="${env_file}.deleted_$(date +%Y%m%d_%H%M%S)"
    mv "$env_file" "$backup_file"
    chmod 600 "$backup_file"
    
    log_success "Secrets deleted for: $app_name"
    log_info "Backup available at: $backup_file"
}

# Export secrets to a file (for migration)
# Args: $1 = app_name, $2 = output_file
export_secrets() {
    local app_name=$1
    local output_file=$2
    local env_file="${SECRETS_DIR}/.env_${app_name}"
    
    if [ ! -f "$env_file" ]; then
        log_error "No secrets found for: $app_name"
        return 1
    fi
    
    cp "$env_file" "$output_file"
    chmod 600 "$output_file"
    log_success "Secrets exported to: $output_file"
}

# Import secrets from a file
# Args: $1 = app_name, $2 = input_file
import_secrets() {
    local app_name=$1
    local input_file=$2
    
    if [ ! -f "$input_file" ]; then
        log_error "Input file not found: $input_file"
        return 1
    fi
    
    init_secrets_dir
    
    local env_file="${SECRETS_DIR}/.env_${app_name}"
    
    # Backup existing if present
    if [ -f "$env_file" ]; then
        cp "$env_file" "${env_file}.backup_$(date +%Y%m%d_%H%M%S)"
    fi
    
    cp "$input_file" "$env_file"
    chmod 600 "$env_file"
    
    log_success "Secrets imported for: $app_name"
}
