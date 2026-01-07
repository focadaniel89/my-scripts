#!/bin/bash

# ==============================================================================
# CREDENTIALS BACKUP SCRIPT
# Backs up all application credentials from ~/.vps-secrets
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"

SECRETS_DIR="${HOME}/.vps-secrets"
BACKUP_DIR="${SECRETS_DIR}/.backup"
RETENTION_DAYS=${RETENTION_DAYS:-30}

init_backup_dir() {
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
        chmod 700 "$BACKUP_DIR"
        log_info "Created backup directory: $BACKUP_DIR"
    fi
}

backup_credentials() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/credentials_${timestamp}.tar.gz"
    
    log_info "Starting credentials backup..."
    
    # Check if there are any credentials to backup
    local cred_count=$(ls -1 "${SECRETS_DIR}"/.env_* 2>/dev/null | wc -l)
    
    if [ $cred_count -eq 0 ]; then
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
        log_info "Backed up $cred_count credential files"
        audit_log "BACKUP_CREDENTIALS" "system" "$cred_count files backed up"
        return 0
    else
        log_error "Backup failed"
        return 1
    fi
}

cleanup_old_backups() {
    log_info "Cleaning up backups older than $RETENTION_DAYS days..."
    
    local deleted=0
    
    find "$BACKUP_DIR" -type f -name "credentials_*.tar.gz" -mtime +${RETENTION_DAYS} -print0 | \
    while IFS= read -r -d '' file; do
        rm -f "$file"
        ((deleted++))
    done
    
    if [ $deleted -gt 0 ]; then
        log_success "Deleted $deleted old backup(s)"
    else
        log_info "No old backups to delete"
    fi
}

list_backups() {
    log_info "Available credential backups:"
    echo ""
    
    if [ ! -d "$BACKUP_DIR" ]; then
        echo "  No backups found"
        return
    fi
    
    local backups=$(ls -1t "$BACKUP_DIR"/credentials_*.tar.gz 2>/dev/null)
    
    if [ -z "$backups" ]; then
        echo "  No backups found"
        return
    fi
    
    printf "  %-30s %-15s %-10s\n" "BACKUP FILE" "DATE" "SIZE"
    printf "  %-30s %-15s %-10s\n" "-----------" "----" "----"
    
    while IFS= read -r backup; do
        local filename=$(basename "$backup")
        local date=$(stat -c %y "$backup" | cut -d' ' -f1)
        local size=$(du -h "$backup" | cut -f1)
        
        printf "  %-30s %-15s %-10s\n" "$filename" "$date" "$size"
    done <<< "$backups"
    
    echo ""
}

restore_backup() {
    local backup_file=$1
    
    if [ ! -f "$backup_file" ]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi
    
    log_warn "This will overwrite existing credentials!"
    read -p "Continue? (y/N): " confirm
    
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        log_info "Restore cancelled"
        return 1
    fi
    
    log_info "Restoring credentials from: $backup_file"
    
    tar -xzf "$backup_file" -C "$SECRETS_DIR"
    
    if [ $? -eq 0 ]; then
        log_success "Credentials restored successfully"
        return 0
    else
        log_error "Restore failed"
        return 1
    fi
}

usage() {
    cat << EOF
Usage: $(basename $0) [COMMAND] [OPTIONS]

Commands:
  backup              Create a new credentials backup
  list                List all available backups
  restore <file>      Restore credentials from backup file
  cleanup             Remove backups older than retention period

Options:
  RETENTION_DAYS=N    Set retention period (default: 30 days)

Examples:
  $(basename $0) backup
  $(basename $0) list
  $(basename $0) restore credentials_20251228_103045.tar.gz
  RETENTION_DAYS=7 $(basename $0) cleanup

EOF
}

# Main execution
main() {
    local command=${1:-backup}
    
    init_backup_dir
    
    case "$command" in
        backup)
            backup_credentials
            cleanup_old_backups
            ;;
        list)
            list_backups
            ;;
        restore)
            if [ -z "${2:-}" ]; then
                log_error "Please specify backup file to restore"
                usage
                exit 1
            fi
            restore_backup "${BACKUP_DIR}/${2}"
            ;;
        cleanup)
            cleanup_old_backups
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            log_error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"
