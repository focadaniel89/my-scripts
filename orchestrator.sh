#!/bin/bash

# ==============================================================================
# VPS ORCHESTRATOR v2.0
# Debian/Ubuntu focused — automatic dependency management
# Usage: ./orchestrator.sh [--help]
# ==============================================================================

set -euo pipefail

VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/preflight.sh"

APPS_CONF="${SCRIPT_DIR}/config/apps.conf"
WORKFLOWS_CONF="${SCRIPT_DIR}/config/workflows.conf"
TOOLS_CONF="${SCRIPT_DIR}/config/tools.conf"

# --- Help ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "VPS Orchestrator v${VERSION}"
    echo ""
    echo "Usage: ./orchestrator.sh [--help]"
    echo ""
    echo "Interactive menu to install and manage VPS applications."
    echo "Designed for Debian/Ubuntu. All dependencies are handled automatically."
    echo ""
    echo "Options:"
    echo "  --help, -h    Show this help message"
    echo ""
    echo "Environment:"
    echo "  FORCE_YES=1   Skip all confirmation prompts (automation mode)"
    echo "  DEBUG=1       Enable verbose debug output"
    exit 0
fi

# ──────────────────────────────────────────────────────────────
# CONFIG READER
# ──────────────────────────────────────────────────────────────
get_config() {
    local file="$1"
    local item_name="$2"
    local key="$3"

    awk -v item="$item_name" -v key="$key" '
        /^\[/ { section=$0; gsub(/[\[\]]/, "", section) }
        section == item && $0 ~ "^"key"=" {
            split($0, a, "=");
            gsub(/^[ \t]+|[ \t]+$/, "", a[2]);
            print a[2];
            exit
        }
    ' "$file"
}

get_app_config() {
    get_config "$APPS_CONF" "$1" "$2"
}

get_workflow_config() {
    get_config "$WORKFLOWS_CONF" "$1" "$2"
}

get_tool_config() {
    get_config "$TOOLS_CONF" "$1" "$2"
}

# ──────────────────────────────────────────────────────────────
# INSTALLATION STATE DETECTION
# ──────────────────────────────────────────────────────────────
is_app_installed() {
    local app_name="$1"

    case "$app_name" in
        docker-engine)
            command -v docker &>/dev/null || return 1
            systemctl is-active --quiet docker 2>/dev/null && return 0
            sudo systemctl start docker &>/dev/null 2>&1 || true
            sleep 2
            systemctl is-active --quiet docker 2>/dev/null && return 0
            return 1
            ;;
        nginx)
            command -v nginx &>/dev/null || return 1
            systemctl is-active --quiet nginx 2>/dev/null && return 0
            sudo systemctl start nginx &>/dev/null || true
            sleep 1
            systemctl is-active --quiet nginx 2>/dev/null && return 0
            return 1
            ;;
        postgres)
            command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null || return 1
            run_sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^postgres$" || return 1
            run_sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^postgres$" && return 0
            run_sudo docker start postgres &>/dev/null || true
            sleep 2
            run_sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^postgres$" && return 0
            return 1
            ;;
        redis)
            if command -v redis-server &>/dev/null || command -v redis-cli &>/dev/null; then
                systemctl is-active --quiet redis-server 2>/dev/null || \
                systemctl is-active --quiet redis 2>/dev/null && return 0
                sudo systemctl start redis-server &>/dev/null || \
                sudo systemctl start redis &>/dev/null || true
                sleep 1
                systemctl is-active --quiet redis-server 2>/dev/null || \
                systemctl is-active --quiet redis 2>/dev/null && return 0
            fi
            return 1
            ;;
        redis-docker)
            command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null || return 1
            run_sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^redis$" && return 0
            run_sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^redis$" || return 1
            run_sudo docker start redis &>/dev/null || true
            sleep 2
            run_sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^redis$" && return 0
            return 1
            ;;
        certbot)
            command -v certbot &>/dev/null && return 0 || return 1
            ;;
        vault)
            command -v vault &>/dev/null && return 0 || return 1
            ;;
        *)
            command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null || return 1
            run_sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${app_name}$" || return 1
            run_sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${app_name}$" && return 0
            run_sudo docker start "$app_name" &>/dev/null || true
            sleep 2
            run_sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${app_name}$" && return 0
            return 1
            ;;
    esac
}

# ──────────────────────────────────────────────────────────────
# DEPENDENCY RESOLUTION
# ──────────────────────────────────────────────────────────────
install_dependencies() {
    local app_name="$1"
    local dependencies
    dependencies=$(get_app_config "$app_name" "dependencies")
    [ -z "$dependencies" ] && return 0

    IFS=',' read -ra DEPS <<< "$dependencies"
    for dep in "${DEPS[@]}"; do
        dep=$(echo "$dep" | xargs)
        if is_app_installed "$dep"; then
            log_success "✓ Dependency already installed: $dep"
            continue
        fi

        log_warn "Dependency not installed: $dep — installing automatically"
        local dep_script
        dep_script=$(find "${SCRIPT_DIR}/apps" -name "$dep" -type d \
            -exec test -f "{}/install.sh" \; -print -quit)

        if [ -z "$dep_script" ]; then
            log_error "Cannot find installer for: $dep (expected: apps/*/$dep/install.sh)"
            return 1
        fi

        log_step "Installing dependency: $dep"
        bash "${dep_script}/install.sh"
        local exit_code=$?

        if [ $exit_code -ne 0 ]; then
            log_error "Dependency installer failed with exit code: $exit_code"
            confirm_action "Continue anyway? (not recommended)" || return 1
        fi

        confirm_action "Did '$dep' install successfully? Continue?" || {
            log_info "You can manually run: ${dep_script}/install.sh"
            return 1
        }
        log_success "Dependency confirmed: $dep"
    done
    return 0
}

install_optional_dependencies() {
    local app_name="$1"
    local optional_deps
    optional_deps=$(get_app_config "$app_name" "optional_dependencies")
    [ -z "$optional_deps" ] && return 0

    IFS=',' read -ra OPT_DEPS <<< "$optional_deps"
    for opt_dep in "${OPT_DEPS[@]}"; do
        opt_dep=$(echo "$opt_dep" | xargs)
        if is_app_installed "$opt_dep"; then
            log_success "✓ Optional dependency already installed: $opt_dep"
            continue
        fi

        local opt_desc
        opt_desc=$(get_app_config "$opt_dep" "description")
        log_step "Optional Enhancement Available: $opt_dep"
        log_info "Description: $opt_desc"

        confirm_action "Install $opt_dep? (recommended for enhanced functionality)" || {
            log_info "Skipping: $opt_dep — install later with ./orchestrator.sh"
            continue
        }

        local opt_script
        opt_script=$(find "${SCRIPT_DIR}/apps" -name "$opt_dep" -type d \
            -exec test -f "{}/install.sh" \; -print -quit)

        if [ -z "$opt_script" ]; then
            log_error "Cannot find installer for: $opt_dep"
            continue
        fi

        bash "${opt_script}/install.sh"
        [ $? -eq 0 ] && log_success "Optional installed: $opt_dep" || \
            log_warn "Optional install had issues — install later if needed"
    done
    return 0
}

# ──────────────────────────────────────────────────────────────
# MENU BUILDER
# ──────────────────────────────────────────────────────────────
show_menu() {
    clear
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║           VPS ORCHESTRATOR  v${VERSION}                       ║"
    echo "║           Debian/Ubuntu · Production Setup               ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""

    local counter=1
    declare -ga apps_list=()  # global so run_selection() can read it

    # ── APPLICATIONS by category ──────────────────────────────
    for category_dir in apps/*/; do
        local category_name
        category_name=$(basename "$category_dir")
        echo "  ┌─ [${category_name}]"

        for app_dir in "${category_dir}"*/; do
            if [ -d "$app_dir" ] && [ -f "${app_dir}install.sh" ]; then
                local app_name display_name installed_label
                app_name=$(basename "$app_dir")
                display_name=$(get_app_config "$app_name" "display_name" 2>/dev/null || echo "")
                [ -z "$display_name" ] && display_name="$app_name"

                apps_list+=("app:${category_name}/${app_name}")

                installed_label=""
                if (is_app_installed "$app_name") &>/dev/null; then
                    installed_label=" ✓"
                fi

                printf "  │  %2d) %-38s%s\n" "$counter" "$display_name" "$installed_label"
                ((counter++))
            fi
        done
        echo "  └───────────────────────────────────────────"
        echo ""
    done

    # ── WORKFLOWS ─────────────────────────────────────────────
    if ls workflows/*.sh 1>/dev/null 2>&1; then
        echo "  ┌─ [workflows]"
        for wf in workflows/*.sh; do
            if [ -f "$wf" ]; then
                local wf_name display_name
                wf_name=$(basename "$wf" .sh)
                display_name=$(get_workflow_config "$wf_name" "display_name" 2>/dev/null || echo "")
                [ -z "$display_name" ] && display_name="Run: ${wf_name}"
                
                apps_list+=("workflow:${wf}")
                printf "  │  %2d) %-38s\n" "$counter" "${display_name}"
                ((counter++))
            fi
        done
        echo "  └───────────────────────────────────────────"
        echo ""
    fi

    # ── TOOLS ─────────────────────────────────────────────────
    if ls tools/*.sh 1>/dev/null 2>&1; then
        echo "  ┌─ [tools]"
        for tool in tools/*.sh; do
            if [ -f "$tool" ]; then
                local tool_name display_name
                tool_name=$(basename "$tool" .sh)
                display_name=$(get_tool_config "$tool_name" "display_name" 2>/dev/null || echo "")
                [ -z "$display_name" ] && display_name="${tool_name}"
                
                apps_list+=("tool:${tool}")
                printf "  │  %2d) %-38s\n" "$counter" "${display_name}"
                ((counter++))
            fi
        done
        echo "  └───────────────────────────────────────────"
        echo ""
    fi

    echo "  ─────────────────────────────────────────────"
    echo "   0) Exit"
    echo "  ─────────────────────────────────────────────"
    echo ""
}

# ──────────────────────────────────────────────────────────────
# RUN SELECTED ITEM
# ──────────────────────────────────────────────────────────────
run_selection() {
    local choice="$1"
    local total="$2"

    if [ "$choice" = "0" ]; then
        echo ""
        log_info "Goodbye! 👋"
        exit 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -ge "$total" ]; then
        log_error "Invalid selection: $choice"
        return 1
    fi

    local selected="${apps_list[$((choice-1))]}"
    local sel_type="${selected%%:*}"
    local sel_val="${selected#*:}"

    # ── APP ─────────────────────────────────────────────────
    if [ "$sel_type" = "app" ]; then
        local category app
        category=$(dirname "$sel_val")
        app=$(basename "$sel_val")

        echo ""
        log_step "Installing: $app"
        local desc
        desc=$(get_app_config "$app" "description" 2>/dev/null || echo "")
        [ -n "$desc" ] && log_info "Description: $desc"
        echo ""

        # Dependencies
        local app_deps
        app_deps=$(get_app_config "$app" "dependencies" 2>/dev/null || echo "")
        if [ -n "$app_deps" ]; then
            log_info "Checking dependencies: $app_deps"
            install_dependencies "$app" || { log_error "Dependency installation failed"; return 1; }
            log_success "All dependencies satisfied"
        else
            log_info "No dependencies required for: $app"
        fi
        echo ""

        # Main installer
        local script_path="${SCRIPT_DIR}/apps/${category}/${app}/install.sh"
        if [ ! -f "$script_path" ]; then
            log_error "Installer not found: $script_path"
            return 1
        fi

        log_step "Starting installer: $app"
        bash "$script_path"
        local exit_code=$?

        echo ""
        if [ $exit_code -ne 0 ]; then
            log_error "Installer exited with code: $exit_code — review output above"
            return 1
        fi

        log_info "Please verify the installation completed successfully."
        if confirm_action "Did '$app' install successfully?"; then
            log_success "Installation confirmed: $app"
            echo ""

            # Optional dependencies
            local app_opt_deps
            app_opt_deps=$(get_app_config "$app" "optional_dependencies" 2>/dev/null || echo "")
            if [ -n "$app_opt_deps" ]; then
                install_optional_dependencies "$app"
            fi

            log_success "══════════════════════════════════════"
            log_success "  Done: $app"
            log_success "══════════════════════════════════════"
        else
            log_warn "Installation not confirmed — you can re-run: $script_path"
        fi
        
        echo ""
        read -rp "Press Enter to return to menu..."

    # ── WORKFLOW ─────────────────────────────────────────────
    elif [ "$sel_type" = "workflow" ]; then
        local wf_name
        wf_name=$(basename "$sel_val" .sh)
        local script_path="${SCRIPT_DIR}/${sel_val}"

        if [ ! -f "$script_path" ]; then
            log_error "Workflow not found: $script_path"
            return 1
        fi

        echo ""
        log_step "Running workflow: $wf_name"
        bash "$script_path"
        local exit_code=$?
        echo ""
        log_info "Workflow finished (exit code: $exit_code)"
        echo ""
        read -rp "Press Enter to return to menu..."

    # ── TOOL ─────────────────────────────────────────────────
    elif [ "$sel_type" = "tool" ]; then
        local tool_name
        tool_name=$(basename "$sel_val" .sh)
        local script_path="${SCRIPT_DIR}/${sel_val}"

        if [ ! -f "$script_path" ]; then
            log_error "Tool not found: $script_path"
            return 1
        fi

        echo ""
        log_step "Running tool: $tool_name"
        bash "$script_path"
        echo ""
        read -rp "Press Enter to return to menu..."
    fi
}

# ──────────────────────────────────────────────────────────────
# STARTUP CHECKS
# ──────────────────────────────────────────────────────────────
preflight_startup

# ──────────────────────────────────────────────────────────────
# MAIN LOOP
# ──────────────────────────────────────────────────────────────
while true; do
    show_menu
    local_counter="${#apps_list[@]}"
    read -rp "Select [0-$((local_counter))]: " choice
    run_selection "$choice" "$((local_counter + 1))" || {
        echo ""
        read -rp "Press Enter to continue..."
    }
done
