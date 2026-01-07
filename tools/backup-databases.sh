#!/bin/bash

# ==============================================================================
# DATABASE BACKUP SCRIPT
# Backs up PostgreSQL, MariaDB, and MongoDB databases
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"

BACKUP_ROOT="/opt/backups"
RETENTION_DAYS=${RETENTION_DAYS:-7}

init_backup_dirs() {
    local dirs=("${BACKUP_ROOT}/postgres" "${BACKUP_ROOT}/mariadb" "${BACKUP_ROOT}/mongodb")
    
    for dir in "${dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            run_sudo mkdir -p "$dir"
            run_sudo chmod 700 "$dir"
        fi
    done
}

backup_postgres() {
    log_info "Backing up PostgreSQL databases..."
    
    if ! docker ps --format '{{.Names}}' | grep -q '^postgres$'; then
        log_warn "PostgreSQL container not running"
        return 1
    fi
    
    # Load PostgreSQL credentials
    local pg_user=$(get_secret "postgres" "POSTGRES_USER")
    local pg_password=$(get_secret "postgres" "DB_PASSWORD")
    
    if [ -z "$pg_user" ]; then
        log_error "PostgreSQL credentials not found"
        return 1
    fi
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_ROOT}/postgres/pg_backup_${timestamp}.sql"
    
    # Backup all databases
    run_sudo docker exec -e PGPASSWORD="$pg_password" postgres \
        pg_dumpall -U "$pg_user" > "$backup_file" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        run_sudo gzip "$backup_file"
        run_sudo chmod 600 "${backup_file}.gz"
        log_success "PostgreSQL backup created: ${backup_file}.gz"
        
        # Show backup size
        local size=$(du -h "${backup_file}.gz" | cut -f1)
        log_info "Backup size: $size"
        audit_log "BACKUP_DATABASE" "postgres" "Size: $size"
        return 0
    else
        log_error "PostgreSQL backup failed"
        return 1
    fi
}

backup_mariadb() {
    log_info "Backing up MariaDB databases..."
    
    if ! docker ps --format '{{.Names}}' | grep -q '^mariadb$'; then
        log_warn "MariaDB container not running"
        return 1
    fi
    
    # Load MariaDB credentials
    local db_user=$(get_secret "mariadb" "DB_USER")
    local db_password=$(get_secret "mariadb" "DB_PASSWORD")
    
    if [ -z "$db_user" ]; then
        log_error "MariaDB credentials not found"
        return 1
    fi
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_ROOT}/mariadb/mariadb_backup_${timestamp}.sql"
    
    # Backup all databases
    run_sudo docker exec mariadb mysqldump -u "$db_user" -p"$db_password" \
        --all-databases --single-transaction --quick --lock-tables=false \
        > "$backup_file" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        run_sudo gzip "$backup_file"
        run_sudo chmod 600 "${backup_file}.gz"
        log_success "MariaDB backup created: ${backup_file}.gz"
        
        local size=$(du -h "${backup_file}.gz" | cut -f1)
        log_info "Backup size: $size"
        audit_log "BACKUP_DATABASE" "mariadb" "Size: $size"
        return 0
    else
        log_error "MariaDB backup failed"
        return 1
    fi
}

backup_mongodb() {
    log_info "Backing up MongoDB databases..."
    
    if ! docker ps --format '{{.Names}}' | grep -q '^mongodb$'; then
        log_warn "MongoDB container not running"
        return 1
    fi
    
    # Load MongoDB credentials
    local db_user=$(get_secret "mongodb" "MONGO_INITDB_ROOT_USERNAME")
    local db_password=$(get_secret "mongodb" "MONGO_INITDB_ROOT_PASSWORD")
    
    if [ -z "$db_user" ]; then
        log_error "MongoDB credentials not found"
        return 1
    fi
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_dir="${BACKUP_ROOT}/mongodb/mongo_backup_${timestamp}"
    
    # Backup all databases
    run_sudo docker exec mongodb mongodump \
        --username="$db_user" \
        --password="$db_password" \
        --authenticationDatabase=admin \
        --out=/tmp/backup 2>/dev/null
    
    if [ $? -eq 0 ]; then
        run_sudo docker cp mongodb:/tmp/backup "$backup_dir"
        run_sudo tar -czf "${backup_dir}.tar.gz" -C "${BACKUP_ROOT}/mongodb" "$(basename $backup_dir)"
        run_sudo rm -rf "$backup_dir"
        run_sudo chmod 600 "${backup_dir}.tar.gz"
        
        log_success "MongoDB backup created: ${backup_dir}.tar.gz"
        
        local size=$(du -h "${backup_dir}.tar.gz" | cut -f1)
        log_info "Backup size: $size"
        audit_log "BACKUP_DATABASE" "mongodb" "Size: $size"
        return 0
    else
        log_error "MongoDB backup failed"
        return 1
    fi
}

cleanup_old_backups() {
    log_info "Cleaning up backups older than $RETENTION_DAYS days..."
    
    local total_deleted=0
    
    for db_type in postgres mariadb mongodb; do
        local deleted=0
        
        if [ -d "${BACKUP_ROOT}/${db_type}" ]; then
            deleted=$(find "${BACKUP_ROOT}/${db_type}" -type f \
                \( -name "*.sql.gz" -o -name "*.tar.gz" \) \
                -mtime +${RETENTION_DAYS} -delete -print | wc -l)
            
            total_deleted=$((total_deleted + deleted))
            
            if [ $deleted -gt 0 ]; then
                log_info "Deleted $deleted old ${db_type} backup(s)"
            fi
        fi
    done
    
    if [ $total_deleted -eq 0 ]; then
        log_info "No old backups to delete"
    else
        log_success "Total deleted: $total_deleted backup(s)"
    fi
}

list_backups() {
    log_info "Available database backups:"
    echo ""
    
    for db_type in postgres mariadb mongodb; do
        local backup_dir="${BACKUP_ROOT}/${db_type}"
        
        if [ ! -d "$backup_dir" ]; then
            continue
        fi
        
        local backups=$(find "$backup_dir" -type f \( -name "*.sql.gz" -o -name "*.tar.gz" \) 2>/dev/null | sort -r)
        
        if [ -z "$backups" ]; then
            continue
        fi
        
        echo "[$db_type]"
        printf "  %-40s %-15s %-10s\n" "BACKUP FILE" "DATE" "SIZE"
        printf "  %-40s %-15s %-10s\n" "-----------" "----" "----"
        
        while IFS= read -r backup; do
            local filename=$(basename "$backup")
            local date=$(stat -c %y "$backup" | cut -d' ' -f1)
            local size=$(du -h "$backup" | cut -f1)
            
            printf "  %-40s %-15s %-10s\n" "$filename" "$date" "$size"
        done <<< "$backups"
        
        echo ""
    done
}

backup_all() {
    local success=0
    local failed=0
    
    log_info "Starting database backups..."
    echo ""
    
    if backup_postgres; then
        ((success++))
    else
        ((failed++))
    fi
    echo ""
    
    if backup_mariadb; then
        ((success++))
    else
        ((failed++))
    fi
    echo ""
    
    if backup_mongodb; then
        ((success++))
    else
        ((failed++))
    fi
    echo ""
    
    cleanup_old_backups
    echo ""
    
    log_success "Backup completed: $success successful, $failed failed"
}

usage() {
    cat << EOF
Usage: $(basename $0) [COMMAND] [OPTIONS]

Commands:
  all                 Backup all databases (default)
  postgres            Backup only PostgreSQL
  mariadb             Backup only MariaDB
  mongodb             Backup only MongoDB
  list                List all available backups
  cleanup             Remove backups older than retention period

Options:
  RETENTION_DAYS=N    Set retention period (default: 7 days)

Examples:
  $(basename $0)                    # Backup all databases
  $(basename $0) postgres           # Backup only PostgreSQL
  $(basename $0) list               # List all backups
  RETENTION_DAYS=14 $(basename $0)  # Backup with 14-day retention

Backups are stored in: $BACKUP_ROOT

EOF
}

# Main execution
main() {
    local command=${1:-all}
    
    init_backup_dirs
    
    case "$command" in
        all)
            backup_all
            ;;
        postgres)
            backup_postgres
            cleanup_old_backups
            ;;
        mariadb)
            backup_mariadb
            cleanup_old_backups
            ;;
        mongodb)
            backup_mongodb
            cleanup_old_backups
            ;;
        list)
            list_backups
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
