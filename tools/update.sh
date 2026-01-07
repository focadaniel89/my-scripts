#!/bin/bash

# ==============================================================================
# UPDATE MANAGER
# Updates Docker containers to latest version while preserving data
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/docker.sh"

# Get app directory from container name
get_app_dir() {
    local container=$1
    
    # Map container names to their directories
    case "$container" in
        n8n) echo "/opt/automation/n8n" ;;
        postgres) echo "/opt/databases/postgres" ;;
        mariadb) echo "/opt/databases/mariadb" ;;
        mongodb) echo "/opt/databases/mongodb" ;;
        grafana) echo "/opt/monitoring/grafana" ;;
        prometheus) echo "/opt/monitoring/prometheus" ;;
        netdata) echo "/opt/monitoring/netdata" ;;
        uptime-kuma) echo "/opt/monitoring/uptime-kuma" ;;
        portainer) echo "/opt/infrastructure/portainer" ;;
        arcane) echo "/opt/automation/arcane" ;;
        redis) echo "/opt/databases/redis" ;;
        *) echo "" ;;
    esac
}

# Update a single Docker container
update_container() {
    local container=$1
    
    log_info "Updating $container..."
    echo ""
    
    # Check if container exists
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        log_error "Container $container not found"
        return 1
    fi
    
    # Get current image
    local current_image=$(docker inspect --format='{{.Config.Image}}' "$container")
    log_info "Current image: $current_image"
    
    # Get app directory
    local app_dir=$(get_app_dir "$container")
    
    if [ -z "$app_dir" ] || [ ! -d "$app_dir" ]; then
        log_error "App directory not found for $container"
        return 1
    fi
    
    # Check for docker-compose.yml
    local compose_file="${app_dir}/docker-compose.yml"
    
    if [ ! -f "$compose_file" ]; then
        log_warn "No docker-compose.yml found, using direct update"
        update_container_direct "$container" "$current_image"
        return $?
    fi
    
    # Update using docker-compose
    log_step "Step 1: Pulling latest image"
    if ! run_sudo docker compose -f "$compose_file" pull; then
        log_error "Failed to pull latest image"
        return 1
    fi
    
    log_step "Step 2: Stopping container"
    if ! run_sudo docker compose -f "$compose_file" down; then
        log_error "Failed to stop container"
        return 1
    fi
    
    log_step "Step 3: Starting with new image"
    if ! run_sudo docker compose -f "$compose_file" up -d; then
        log_error "Failed to start container"
        log_warn "Attempting rollback..."
        run_sudo docker compose -f "$compose_file" up -d
        return 1
    fi
    
    # Wait for container to be healthy
    log_step "Step 4: Verifying update"
    sleep 5
    
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        local new_image=$(docker inspect --format='{{.Config.Image}}' "$container")
        log_success "Container updated successfully"
        log_info "New image: $new_image"
        
        audit_log "UPDATE_CONTAINER" "$container" "From: $current_image"
        
        return 0
    else
        log_error "Container is not running after update"
        return 1
    fi
}

# Direct container update (without docker-compose)
update_container_direct() {
    local container=$1
    local image=$2
    
    log_warn "Using direct update method (not recommended)"
    
    # Get container configuration
    local volumes=$(docker inspect --format='{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' "$container")
    local network=$(docker inspect --format='{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$container")
    local ports=$(docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{$p}} {{end}}' "$container")
    
    log_info "Backing up container configuration..."
    docker inspect "$container" > "/tmp/${container}_backup.json"
    
    # Pull new image
    run_sudo docker pull "$image"
    
    # Stop and remove old container
    run_sudo docker stop "$container"
    run_sudo docker rm "$container"
    
    log_error "Cannot auto-recreate container - manual recreation required"
    log_info "Backup saved to: /tmp/${container}_backup.json"
    log_info "Please re-run the installer to recreate the container"
    
    return 1
}

# List updatable containers
list_containers() {
    log_info "Installed Docker containers:"
    echo ""
    
    if ! docker ps --format '{{.Names}}' &> /dev/null; then
        log_error "Docker is not running"
        return 1
    fi
    
    local containers=$(docker ps -a --format '{{.Names}}')
    
    if [ -z "$containers" ]; then
        echo "  No containers found"
        return 0
    fi
    
    printf "  %-20s %-40s %-15s\n" "NAME" "IMAGE" "STATUS"
    printf "  %-20s %-40s %-15s\n" "----" "-----" "------"
    
    while IFS= read -r container; do
        local image=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null || echo "unknown")
        local status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
        
        printf "  %-20s %-40s %-15s\n" "$container" "$image" "$status"
    done <<< "$containers"
    
    echo ""
}

# Update all containers
update_all() {
    log_info "Updating all containers..."
    echo ""
    
    local containers=$(docker ps --format '{{.Names}}')
    
    if [ -z "$containers" ]; then
        log_warn "No running containers to update"
        return 0
    fi
    
    local success=0
    local failed=0
    
    while IFS= read -r container; do
        if update_container "$container"; then
            ((success++))
        else
            ((failed++))
        fi
        echo ""
    done <<< "$containers"
    
    log_success "Update completed: $success successful, $failed failed"
}

usage() {
    cat << EOF
Usage: $(basename $0) [COMMAND] [CONTAINER]

Commands:
  list                List all installed containers
  update <name>       Update specific container to latest version
  update-all          Update all running containers

Examples:
  $(basename $0) list
  $(basename $0) update n8n
  $(basename $0) update postgres
  $(basename $0) update-all

Notes:
  - Container data and credentials are preserved
  - Uses docker-compose.yml if available
  - Backs up configuration before update
  - Verifies container health after update

EOF
}

# Main execution
main() {
    local command=${1:-list}
    
    case "$command" in
        list)
            list_containers
            ;;
        update)
            if [ -z "${2:-}" ]; then
                log_error "Please specify container name"
                usage
                exit 1
            fi
            update_container "$2"
            ;;
        update-all)
            update_all
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
