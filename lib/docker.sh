#!/bin/bash

# ==============================================================================
# DOCKER OPERATIONS LIBRARY
# Provides Docker-specific functionality for container management
# ==============================================================================

set -euo pipefail

# Source required libraries
DOCKER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${DOCKER_LIB_DIR}/utils.sh" ]; then
    source "${DOCKER_LIB_DIR}/utils.sh"
fi

# Check if Docker is installed and running
check_docker() {
    if ! command -v docker &> /dev/null; then
        return 1
    fi
    
    if ! run_sudo docker info &> /dev/null; then
        log_warn "Docker is installed but not running"
        log_info "Starting Docker daemon..."
        
        # Try to start Docker service
        local start_output
        start_output=$(run_sudo systemctl start docker 2>&1)
        local start_result=$?
        
        if [ $start_result -eq 0 ]; then
            log_success "Docker daemon started"
            sleep 3  # Wait for Docker to be ready
            
            # Verify Docker is now running
            if run_sudo docker info &> /dev/null; then
                return 0
            else
                log_error "Docker started but not responding"
                log_info "Checking Docker status..."
                run_sudo systemctl status docker --no-pager -l || true
                return 2
            fi
        else
            log_error "Failed to start Docker daemon"
            log_info "Error output: $start_output"
            log_info "Checking Docker service status..."
            run_sudo systemctl status docker --no-pager -l || true
            log_info "Checking Docker socket..."
            run_sudo ls -la /var/run/docker.sock 2>&1 || log_warn "Docker socket not found"
            return 2
        fi
    fi
    
    # Docker is already running
    return 0
}

# Check if Docker Compose is available
check_docker_compose() {
    if run_sudo docker compose version &> /dev/null; then
        echo "docker compose"
        return 0
    elif command -v docker-compose &> /dev/null; then
        echo "docker-compose"
        return 0
    else
        return 1
    fi
}

# Find available subnet in Docker's private range (172.16-31.0.0/16)
# Returns: Available subnet and gateway in format "SUBNET:GATEWAY"
# Example output: "172.20.0.0/16:172.20.0.1"
find_available_subnet() {
    log_info "Finding available subnet..."
    
    # Get all existing subnets
    local existing_subnets=$(run_sudo docker network inspect $(run_sudo docker network ls -q) 2>/dev/null | grep '"Subnet"' | awk -F'"' '{print $4}' | sort -u)
    
    # Try subnet ranges from 172.16.0.0/16 to 172.31.0.0/16 (Docker private range)
    for i in {16..31}; do
        local test_subnet="172.$i.0.0/16"
        local test_prefix="172.$i"
        
        # Check if this subnet overlaps with any existing subnet
        local overlaps=false
        while IFS= read -r existing; do
            [ -z "$existing" ] && continue
            
            # Extract first 2 octets from existing subnet
            local existing_prefix=$(echo "$existing" | cut -d. -f1-2)
            
            if [ "$existing_prefix" = "$test_prefix" ]; then
                overlaps=true
                break
            fi
        done <<< "$existing_subnets"
        
        if [ "$overlaps" = "false" ]; then
            local gateway="172.$i.0.1"
            echo "$test_subnet:$gateway"
            return 0
        fi
    done
    
    # No available subnet found
    log_error "No available subnets in Docker's private range (172.16-31.0.0/16)"
    log_info "Existing subnets:"
    echo "$existing_subnets" | while read -r subnet; do
        [ -n "$subnet" ] && log_info "  - $subnet"
    done
    return 1
}

# Create Docker network with automatic subnet detection
# Args: $1 = network_name
create_docker_network() {
    local network_name=$1
    
    if ! run_sudo docker network inspect "$network_name" &> /dev/null; then
        log_info "Creating Docker network: $network_name"
        
        # Find available subnet
        local subnet_info=$(find_available_subnet)
        if [ $? -ne 0 ]; then
            log_error "Failed to find available subnet"
            return 1
        fi
        
        local subnet=$(echo "$subnet_info" | cut -d: -f1)
        local gateway=$(echo "$subnet_info" | cut -d: -f2)
        
        log_success "Found available subnet: $subnet"
        log_info "Creating network with gateway: $gateway"
        
        if run_sudo docker network create "$network_name" --subnet="$subnet" --gateway="$gateway"; then
            log_success "Network created: $network_name ($subnet)"
            return 0
        else
            log_error "Failed to create network: $network_name"
            return 1
        fi
    else
        log_info "Docker network already exists: $network_name"
        return 0
    fi
}

# Create Docker network if it doesn't exist
# Args: $1 = network_name
create_docker_network() {
    local network_name=$1
    
    if ! run_sudo docker network inspect "$network_name" &> /dev/null; then
        log_info "Creating Docker network: $network_name"
        run_sudo docker network create "$network_name"
        return $?
    else
        log_info "Docker network already exists: $network_name"
        return 0
    fi
}

# Deploy application using docker-compose
# Args: $1 = app_directory
deploy_with_compose() {
    local app_dir=$1
    
    if [ ! -d "$app_dir" ]; then
        log_error "Directory not found: $app_dir"
        return 1
    fi
    
    if [ ! -f "$app_dir/docker-compose.yml" ]; then
        log_error "docker-compose.yml not found in: $app_dir"
        return 1
    fi
    
    log_info "Deploying with Docker Compose..."
    
    local compose_cmd=$(check_docker_compose)
    if [ $? -ne 0 ]; then
        log_error "Docker Compose not available"
        return 1
    fi
    
    cd "$app_dir" || return 1
    
    if [ "$compose_cmd" = "docker compose" ]; then
        run_sudo docker compose up -d
    else
        run_sudo docker-compose up -d
    fi
    
    local result=$?
    cd - > /dev/null
    
    return $result
}

# Stop and remove container
# Args: $1 = container_name
remove_container() {
    local container_name=$1
    
    if run_sudo docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log_info "Removing container: $container_name"
        run_sudo docker stop "$container_name" 2>/dev/null
        run_sudo docker rm "$container_name" 2>/dev/null
        return 0
    else
        log_info "Container not found: $container_name"
        return 1
    fi
}

# Check container health status
# Args: $1 = container_name
check_container_health() {
    local container_name=$1
    local max_attempts=${2:-30}
    local attempt=0
    
    log_info "Checking container health: $container_name"
    
    # Wait for container to start
    sleep 2
    
    while [ $attempt -lt $max_attempts ]; do
        if ! run_sudo docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
            log_warn "Container not running: $container_name"
            return 1
        fi
        
        # Check if container has health check defined
        local health_status=$(run_sudo docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null)
        
        if [ -n "$health_status" ]; then
            # Container has health check
            if [ "$health_status" = "healthy" ]; then
                log_success "Container is healthy: $container_name"
                return 0
            elif [ "$health_status" = "unhealthy" ]; then
                log_error "Container is unhealthy: $container_name"
                return 1
            fi
            # Status is "starting", continue waiting
        else
            # No health check defined, just check if running
            local is_running=$(run_sudo docker inspect --format='{{.State.Running}}' "$container_name" 2>/dev/null)
            if [ "$is_running" = "true" ]; then
                log_success "Container is running: $container_name"
                return 0
            fi
        fi
        
        attempt=$((attempt + 1))
        echo -n "."
        sleep 2
    done
    
    echo ""
    log_warn "Health check timeout for: $container_name"
    return 2
}

# Get container logs
# Args: $1 = container_name, $2 = lines (default: 50)
show_container_logs() {
    local container_name=$1
    local lines=${2:-50}
    
    if run_sudo docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo ""
        echo "${BLUE}Last ${lines} log lines for ${container_name}:${NC}"
        echo "${BLUE}════════════════════════════════════════${NC}"
        run_sudo docker logs --tail "$lines" "$container_name" 2>&1
        echo "${BLUE}════════════════════════════════════════${NC}"
        echo ""
    else
        log_error "Container not found: $container_name"
        return 1
    fi
}

# Restart container
# Args: $1 = container_name
restart_container() {
    local container_name=$1
    
    if run_sudo docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log_info "Restarting container: $container_name"
        run_sudo docker restart "$container_name"
        return $?
    else
        log_error "Container not running: $container_name"
        return 1
    fi
}

# List containers (running and stopped)
list_containers() {
    echo ""
    echo "${GREEN}═══════════════════════════════════════════${NC}"
    echo "${GREEN}  Docker Containers${NC}"
    echo "${GREEN}═══════════════════════════════════════════${NC}"
    echo ""
    
    run_sudo docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || {
        log_error "Failed to list containers"
        return 1
    }
    
    echo ""
}

# Get container IP address
# Args: $1 = container_name, $2 = network_name (optional)
get_container_ip() {
    local container_name=$1
    local network_name=${2:-"bridge"}
    
    run_sudo docker inspect -f "{{.NetworkSettings.Networks.${network_name}.IPAddress}}" "$container_name" 2>/dev/null
}

# Pull Docker image with retry logic (handles rate limits and network issues)
# Args: $1 = image_name, $2 = max_retries (optional, default 3)
pull_docker_image() {
    local image_name=$1
    local max_retries=${2:-3}
    local retry_delay=5
    local attempt=1
    
    log_info "Pulling Docker image: $image_name"
    
    while [ $attempt -le $max_retries ]; do
        if [ $attempt -gt 1 ]; then
            log_info "Retry attempt $attempt/$max_retries after ${retry_delay}s delay..."
            sleep $retry_delay
            # Exponential backoff: 5s, 10s, 20s
            retry_delay=$((retry_delay * 2))
        fi
        
        if run_sudo docker pull "$image_name" 2>&1; then
            log_success "Successfully pulled: $image_name"
            return 0
        else
            local exit_code=$?
            log_warn "Failed to pull image (attempt $attempt/$max_retries)"
            
            # Check if it's a rate limit error
            if run_sudo docker pull "$image_name" 2>&1 | grep -qi "rate limit\|too many requests"; then
                log_warn "Docker Hub rate limit detected, waiting longer..."
                sleep $((retry_delay * 2))
            fi
        fi
        
        attempt=$((attempt + 1))
    done
    
    log_error "Failed to pull image after $max_retries attempts: $image_name"
    return 1
}

# Check if image exists locally
# Args: $1 = image_name
image_exists() {
    local image_name=$1
    
    run_sudo docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${image_name}$"
}

# Create volume if it doesn't exist
# Args: $1 = volume_name
create_volume() {
    local volume_name=$1
    
    if ! run_sudo docker volume inspect "$volume_name" &> /dev/null; then
        log_info "Creating Docker volume: $volume_name"
        run_sudo docker volume create "$volume_name"
        return $?
    else
        log_info "Docker volume already exists: $volume_name"
        return 0
    fi
}

# Remove volume
# Args: $1 = volume_name
remove_volume() {
    local volume_name=$1
    
    if run_sudo docker volume inspect "$volume_name" &> /dev/null; then
        log_info "Removing Docker volume: $volume_name"
        run_sudo docker volume rm "$volume_name"
        return $?
    else
        log_info "Docker volume not found: $volume_name"
        return 1
    fi
}

# List all volumes
list_volumes() {
    echo ""
    echo "${GREEN}═══════════════════════════════════════════${NC}"
    echo "${GREEN}  Docker Volumes${NC}"
    echo "${GREEN}═══════════════════════════════════════════${NC}"
    echo ""
    
    run_sudo docker volume ls 2>/dev/null || {
        log_error "Failed to list volumes"
        return 1
    }
    
    echo ""
}

# Prune unused Docker resources
docker_cleanup() {
    log_info "Cleaning up unused Docker resources..."
    
    echo ""
    echo "${YELLOW}This will remove:${NC}"
    echo "  • Stopped containers"
    echo "  • Unused networks"
    echo "  • Dangling images"
    echo "  • Build cache"
    echo ""
    
    if confirm_action "Proceed with cleanup?"; then
        run_sudo docker system prune -f
        log_success "Docker cleanup completed"
    else
        log_info "Cleanup cancelled"
    fi
}

# Export container configuration
# Args: $1 = container_name, $2 = output_file
export_container_config() {
    local container_name=$1
    local output_file=$2
    
    if ! run_sudo docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log_error "Container not found: $container_name"
        return 1
    fi
    
    run_sudo docker inspect "$container_name" > "$output_file"
    log_success "Container config exported to: $output_file"
}

# Check Docker system info
docker_system_info() {
    echo ""
    echo "${GREEN}═══════════════════════════════════════════${NC}"
    echo "${GREEN}  Docker System Information${NC}"
    echo "${GREEN}═══════════════════════════════════════════${NC}"
    echo ""
    
    run_sudo docker version
    echo ""
    run_sudo docker info
    echo ""
}
