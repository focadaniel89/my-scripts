#!/bin/bash

# VPS Orchestrator - Automatic dependency management
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/docker.sh"

APPS_CONF="${SCRIPT_DIR}/config/apps.conf"

# Function to read app config from apps.conf
get_app_config() {
    local app_name="$1"
    local key="$2"
    
    # Read value from apps.conf
    awk -v app="$app_name" -v key="$key" '
        /^\[/ { section=$0; gsub(/[\[\]]/, "", section) }
        section == app && $0 ~ "^"key"=" { 
            split($0, a, "="); 
            gsub(/^[ \t]+|[ \t]+$/, "", a[2]);
            print a[2];
            exit
        }
    ' "$APPS_CONF"
}

# Function to check if an app is installed AND running
is_app_installed() {
    local app_name="$1"
    
    case "$app_name" in
        docker-engine)
            if command -v docker &>/dev/null; then
                if systemctl is-active --quiet docker 2>/dev/null; then
                     return 0
                else
                     # Docker is installed but not active - start it
                     if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
                         sudo systemctl start docker &>/dev/null || true
                         sleep 2
                         systemctl is-active --quiet docker 2>/dev/null && return 0
                     fi
                     return 1
                fi
            else
                return 1
            fi
            ;;
        nginx)
            if command -v nginx &>/dev/null; then
                systemctl is-active --quiet nginx 2>/dev/null && return 0
                
                # Try to start
                if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
                     sudo systemctl start nginx &>/dev/null || true
                     sleep 1
                     systemctl is-active --quiet nginx 2>/dev/null && return 0
                fi
                return 1
            else
                return 1
            fi
            ;;
        postgres)
            if command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
                # Check if container exists first (stopped or running)
                if run_sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^postgres$"; then
                    # Container exists, is it running?
                    if run_sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^postgres$"; then
                        return 0
                    else
                        # Container exists but stopped - try start
                        run_sudo docker start postgres &>/dev/null || true
                        sleep 2
                        run_sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^postgres$" && return 0
                        return 1
                    fi
                else
                    return 1
                fi
            else
                return 1
            fi
            ;;
        redis)
            # Check if Redis native (host) is installed
            if command -v redis-server &>/dev/null || command -v redis-cli &>/dev/null; then
                # Package exists, check if service is running
                if systemctl is-active --quiet redis-server 2>/dev/null || systemctl is-active --quiet redis 2>/dev/null; then
                    return 0
                else
                    # Try to start the service
                    if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
                         sudo systemctl start redis-server &>/dev/null || sudo systemctl start redis &>/dev/null || true
                         sleep 1
                         if systemctl is-active --quiet redis-server 2>/dev/null || systemctl is-active --quiet redis 2>/dev/null; then
                             return 0
                         fi
                    fi
                    return 1
                fi
            else
                # Redis not installed
                return 1
            fi
            ;;
        redis-docker)
            # Check if Redis container exists and is running
            if command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
                if run_sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^redis$"; then
                    return 0
                elif run_sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^redis$"; then
                    # Container exists but stopped - try to start
                    run_sudo docker start redis &>/dev/null || true
                    sleep 2
                    run_sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^redis$" && return 0
                    return 1
                else
                    return 1
                fi
            else
                return 1
            fi
            ;;
        certbot)
            command -v certbot &>/dev/null && return 0 || return 1
            ;;
        *)
            # For other apps, check if Docker container exists and is running
            if command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
                 if run_sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${app_name}$"; then
                    if run_sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${app_name}$"; then
                        return 0
                    else
                        # specific app container stopped - try start
                        run_sudo docker start "$app_name" &>/dev/null || true
                        sleep 2
                        run_sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${app_name}$" && return 0
                        return 1
                    fi
                 else
                    return 1
                 fi
            else
                return 1
            fi
            ;;
    esac
}

# Function to install dependencies recursively
install_dependencies() {
    local app_name="$1"
    local dependencies=$(get_app_config "$app_name" "dependencies")
    
    # If no dependencies, return
    [ -z "$dependencies" ] && return 0
    
    # Split dependencies by comma
    IFS=',' read -ra DEPS <<< "$dependencies"
    
    for dep in "${DEPS[@]}"; do
        dep=$(echo "$dep" | xargs) # trim whitespace
        
        if ! is_app_installed "$dep"; then
            log_warn "Dependency not installed: $dep"
            log_info "Application '$app_name' requires '$dep'"
            log_info "Installing dependency automatically: $dep"
            echo ""
            
            # Find and run dependency installer
            dep_script=$(find "${SCRIPT_DIR}/apps" -name "$dep" -type d -exec test -f "{}/install.sh" \; -print -quit)
            
            if [ -n "$dep_script" ]; then
                # Install dependency - run script and WAIT for completion
                log_info "═══════════════════════════════════════════"
                log_info "  Starting installer: $dep"
                log_info "═══════════════════════════════════════════"
                echo ""
                
                bash "${dep_script}/install.sh"
                DEP_EXIT_CODE=$?
                
                echo ""
                log_info "═══════════════════════════════════════════"
                log_info "  Installer finished: $dep (exit code: $DEP_EXIT_CODE)"
                log_info "═══════════════════════════════════════════"
                
                # Check exit code
                if [ $DEP_EXIT_CODE -ne 0 ]; then
                    log_error "Installer exited with error code: $DEP_EXIT_CODE"
                    log_error "Dependency installation failed: $dep"
                    
                    if confirm_action "Continue anyway? (Not recommended)"; then
                        log_warn "Continuing despite error..."
                    else
                        log_error "Installation aborted by user"
                        return 1
                    fi
                fi
                
                # Manual verification step
                echo ""
                log_info "Please verify the installation completed successfully."
                log_info "Check the output above for any errors or warnings."
                echo ""
                
                if ! confirm_action "Did '$dep' install successfully? Continue with next dependency?"; then
                    log_error "Installation stopped by user"
                    log_info "You can manually run: ${dep_script}/install.sh"
                    return 1
                fi
                
                log_success "Dependency confirmed: $dep"
                echo ""
            else
                log_error "Cannot find installer for: $dep"
                log_error "Expected location: apps/*/$dep/install.sh"
                return 1
            fi
        else
            log_success "✓ Dependency already installed: $dep"
        fi
    done
    
    return 0
}

# Function to handle optional dependencies (recommended but not required)
install_optional_dependencies() {
    local app_name="$1"
    local optional_deps=$(get_app_config "$app_name" "optional_dependencies")
    
    # If no optional dependencies, return
    [ -z "$optional_deps" ] && return 0
    
    # Split dependencies by comma
    IFS=',' read -ra OPT_DEPS <<< "$optional_deps"
    
    for opt_dep in "${OPT_DEPS[@]}"; do
        opt_dep=$(echo "$opt_dep" | xargs) # trim whitespace
        
        if ! is_app_installed "$opt_dep"; then
            log_info "═══════════════════════════════════════════"
            log_info "  Optional Enhancement Available"
            log_info "═══════════════════════════════════════════"
            echo ""
            
            # Get description for optional dependency
            local opt_desc=$(get_app_config "$opt_dep" "description")
            log_info "Application: $opt_dep"
            log_info "Description: $opt_desc"
            log_info "Status: Not installed (optional for $app_name)"
            echo ""
            
            if confirm_action "Install $opt_dep? (Recommended for enhanced functionality)"; then
                log_info "Installing optional dependency: $opt_dep"
                echo ""
                
                # Find and run optional dependency installer
                opt_script=$(find "${SCRIPT_DIR}/apps" -name "$opt_dep" -type d -exec test -f "{}/install.sh" \; -print -quit)
                
                if [ -n "$opt_script" ]; then
                    log_info "═══════════════════════════════════════════"
                    log_info "  Starting installer: $opt_dep"
                    log_info "═══════════════════════════════════════════"
                    echo ""
                    
                    bash "${opt_script}/install.sh"
                    OPT_EXIT_CODE=$?
                    
                    echo ""
                    log_info "═══════════════════════════════════════════"
                    log_info "  Installer finished: $opt_dep (exit code: $OPT_EXIT_CODE)"
                    log_info "═══════════════════════════════════════════"
                    
                    if [ $OPT_EXIT_CODE -ne 0 ]; then
                        log_warn "Optional dependency installation had issues"
                        log_info "You can install it later manually if needed"
                    else
                        log_success "Optional dependency installed: $opt_dep"
                    fi
                    echo ""
                else
                    log_error "Cannot find installer for: $opt_dep"
                fi
            else
                log_info "Skipping optional dependency: $opt_dep"
                log_info "You can install it later: ./orchestrator.sh"
                echo ""
            fi
        else
            log_success "✓ Optional dependency already installed: $opt_dep"
        fi
    done
    
    return 0
}

clear
echo "=============================================="
echo "  Instalare Aplicații"
echo "=============================================="
echo ""

# List all available applications
echo "AVAILABLE APPLICATIONS:"
echo ""

counter=1
declare -a apps_list=()

for category in apps/*/; do
    category_name=$(basename "$category")
    echo "[$category_name]"
    
    for app_dir in "$category"*/; do
        if [ -d "$app_dir" ] && [ -f "${app_dir}install.sh" ]; then
            app_name=$(basename "$app_dir")
            apps_list+=("${category_name}/${app_name}")
            
            # Show if installed (disable exit on error for this check)
            # Use subshell to prevent script termination on error
            # Safely check installation status without breaking on error
            installed_status="  "
            if (is_app_installed "$app_name") &>/dev/null; then
                installed_status="✓ Installed"
            fi
            
            if [ -n "$installed_status" ] && [ "$installed_status" = "✓ Installed" ]; then
                printf "   %2d) %-25s [%s]\n" "$counter" "$app_name" "$installed_status"
            else
                printf "   %2d) %s\n" "$counter" "$app_name"
            fi
            ((counter++))
        fi
    done
    echo ""
done

echo "=============================================="
echo " 0) Exit"
echo "=============================================="
echo ""
read -p "Select application number: " choice

if [ "$choice" = "0" ]; then
    echo "Goodbye!"
    exit 0
fi

# Validate that choice is a number
if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    echo "Invalid selection!"
    exit 1
fi

if [ "$choice" -ge 1 ] && [ "$choice" -lt "$counter" ]; then
    selected="${apps_list[$((choice-1))]}"
    category=$(dirname "$selected")
    app=$(basename "$selected")
    
    echo ""
    echo "=============================================="
    echo "Installing: $app"
    echo "=============================================="
    echo ""
    
    # Check and install dependencies (if any)
    log_step "Checking dependencies..."
    
    # Get dependencies for this app (may be empty)
    app_deps=$(get_app_config "$app" "dependencies" 2>/dev/null || echo "")
    
    if [ -n "$app_deps" ]; then
        log_info "Dependencies found: $app_deps"
        if install_dependencies "$app"; then
            log_success "All dependencies satisfied"
        else
            log_error "Dependency installation failed"
            exit 1
        fi
    else
        log_info "No dependencies required for: $app"
    fi
    echo ""
    
    # Run app installer with manual confirmation
    script_path="${SCRIPT_DIR}/apps/${category}/${app}/install.sh"
    
    if [ -f "$script_path" ]; then
        log_info "═══════════════════════════════════════════"
        log_info "  Starting installer: $app (main application)"
        log_info "═══════════════════════════════════════════"
        echo ""
        
        bash "$script_path"
        APP_EXIT_CODE=$?
        
        echo ""
        log_info "═══════════════════════════════════════════"
        log_info "  Installer finished: $app (exit code: $APP_EXIT_CODE)"
        log_info "═══════════════════════════════════════════"
        
        # Check exit code
        if [ $APP_EXIT_CODE -ne 0 ]; then
            log_error "Installer exited with error code: $APP_EXIT_CODE"
            log_error "Application installation may have failed: $app"
            echo ""
            log_warn "Please review the output above for errors"
            exit 1
        fi
        
        # Manual verification step
        echo ""
        log_info "Please verify the installation completed successfully."
        log_info "Check the output above for any errors or warnings."
        echo ""
        
        if confirm_action "Did '$app' install successfully?"; then
            log_success "Installation confirmed by user: $app"
            echo ""
            
            # Check for optional dependencies AFTER main app installation
            log_step "Checking optional enhancements..."
            app_opt_deps=$(get_app_config "$app" "optional_dependencies" 2>/dev/null || echo "")
            
            if [ -n "$app_opt_deps" ]; then
                log_info "Optional enhancements available: $app_opt_deps"
                install_optional_dependencies "$app"
            else
                log_info "No optional enhancements for: $app"
            fi
            echo ""
            
            log_success "═══════════════════════════════════════════"
            log_success "  Installation Complete: $app"
            log_success "═══════════════════════════════════════════"
        else
            log_warn "Installation not confirmed by user"
            log_info "You can manually run: $script_path"
            exit 1
        fi
    else
        echo "ERROR: Install script not found: $script_path"
        exit 1
    fi
else
    echo "Invalid selection!"
    exit 1
fi
