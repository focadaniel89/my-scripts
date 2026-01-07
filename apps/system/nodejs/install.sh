#!/bin/bash

# ==============================================================================
# NODE.JS DEVELOPMENT ENVIRONMENT
# Node Version Manager (NVM) with multiple Node.js versions support
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"

APP_NAME="nodejs"
NVM_VERSION="v0.40.1"

log_info "═══════════════════════════════════════════"
log_info "  Installing Node.js via NVM"
log_info "═══════════════════════════════════════════"
echo ""

# Check dependencies
log_step "Step 1: Checking dependencies"
COMMANDS=("curl" "git" "make" "gcc" "g++")
MISSING=()

for cmd in "${COMMANDS[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
        MISSING+=("$cmd")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    log_warn "Missing dependencies: ${MISSING[*]}"
    log_info "Installing..."
    pkg_update
    
    if is_debian_based; then
        pkg_install curl git build-essential
    elif is_rhel_based; then
        pkg_install curl git gcc gcc-c++ make
    else
        log_error "Unsupported OS: $OS_ID"
        exit 1
    fi
    
    log_success "Dependencies installed"
else
    log_success "All dependencies available"
fi
echo ""

# Check for existing NVM installation
log_step "Step 2: Checking for existing NVM installation"
if [ -d "$HOME/.nvm" ]; then
    log_success "✓ NVM is already installed"
    if confirm_action "Reinstall/Update?"; then
        log_info "Proceeding with NVM update..."
    else
        log_info "Installation cancelled"
        exit 0
    fi
fi
echo ""

# Install/Update NVM
log_step "Step 3: Installing NVM (Node Version Manager)"
log_info "NVM version: $NVM_VERSION"

curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" | bash

if [ $? -ne 0 ]; then
    log_error "NVM installation failed"
    exit 1
fi

log_success "NVM installed"
echo ""

# Load NVM
log_step "Step 4: Loading NVM environment"
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"

if command -v nvm &> /dev/null; then
    log_success "NVM loaded successfully"
else
    log_error "Failed to load NVM"
    exit 1
fi
echo ""

# Install Node.js LTS
log_step "Step 5: Installing Node.js LTS version"
log_info "This may take a few minutes..."

nvm install --lts
nvm use --lts
nvm alias default node

if command -v node &> /dev/null; then
    NODE_VERSION=$(node --version)
    NPM_VERSION=$(npm --version)
    log_success "Node.js installed: $NODE_VERSION"
    log_success "npm installed: v$NPM_VERSION"
else
    log_error "Node.js installation failed"
    exit 1
fi
echo ""

# Update npm to latest
log_step "Step 6: Updating npm to latest version"
npm install -g npm@latest
NPM_VERSION=$(npm --version)
log_success "npm updated: v$NPM_VERSION"
echo ""

# Install common global packages
log_step "Step 7: Installing common global packages"
log_info "Installing essential development tools..."

GLOBAL_PACKAGES=(
    "pm2"           # Process manager
    "yarn"          # Alternative package manager
    "typescript"    # TypeScript compiler
    "ts-node"       # TypeScript execution
    "nodemon"       # Auto-restart development server
    "eslint"        # JavaScript linter
    "prettier"      # Code formatter
)

for package in "${GLOBAL_PACKAGES[@]}"; do
    log_info "Installing $package..."
    npm install -g "$package" --silent
done

log_success "Global packages installed"
echo ""

# Create version management script
log_step "Step 8: Creating version management script"
cat > "$HOME/.nvm/manage-node.sh" << 'EOFSCRIPT'
#!/bin/bash

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

case "$1" in
    list)
        echo -e "${BLUE}Installed Node.js versions:${NC}"
        nvm list
        ;;
    current)
        echo -e "${GREEN}Current version:${NC} $(node --version)"
        echo -e "${GREEN}npm version:${NC} $(npm --version)"
        ;;
    install)
        [ -z "$2" ] && echo "Usage: $0 install <version>" && exit 1
        echo -e "${BLUE}Installing Node.js $2...${NC}"
        nvm install "$2"
        ;;
    use)
        [ -z "$2" ] && echo "Usage: $0 use <version>" && exit 1
        echo -e "${BLUE}Switching to Node.js $2...${NC}"
        nvm use "$2"
        ;;
    default)
        [ -z "$2" ] && echo "Usage: $0 default <version>" && exit 1
        echo -e "${BLUE}Setting default to Node.js $2...${NC}"
        nvm alias default "$2"
        ;;
    *)
        echo "Node.js Version Management"
        echo "Usage: $0 {list|current|install|use|default} [version]"
        echo ""
        echo "Commands:"
        echo "  list              - List installed versions"
        echo "  current           - Show current version"
        echo "  install <ver>     - Install Node.js version"
        echo "  use <ver>         - Switch to version"
        echo "  default <ver>     - Set default version"
        echo ""
        echo "Examples:"
        echo "  $0 install 18.20.0"
        echo "  $0 install --lts"
        echo "  $0 use 18"
        echo "  $0 default 20"
        ;;
esac
EOFSCRIPT

chmod +x "$HOME/.nvm/manage-node.sh"
ln -sf "$HOME/.nvm/manage-node.sh" /usr/local/bin/manage-node 2>/dev/null || \
    run_sudo ln -sf "$HOME/.nvm/manage-node.sh" /usr/local/bin/manage-node

log_success "Version management script created"
echo ""

# Display installation summary
log_success "═══════════════════════════════════════════"
log_success "  Node.js Installation Complete!"
log_success "═══════════════════════════════════════════"
echo ""

log_info "📦 Installed versions:"
echo "  Node.js:     $NODE_VERSION"
echo "  npm:         v$NPM_VERSION"
echo "  NVM:         $NVM_VERSION"
echo ""

log_info "🔧 Global packages:"
echo "  pm2          - Process manager for Node.js"
echo "  yarn         - Fast, reliable package manager"
echo "  typescript   - TypeScript compiler"
echo "  ts-node      - Execute TypeScript directly"
echo "  nodemon      - Auto-restart on file changes"
echo "  eslint       - JavaScript linting tool"
echo "  prettier     - Code formatter"
echo ""

log_info "📁 NVM directory:"
echo "  Location: $HOME/.nvm/"
echo "  Config:   $HOME/.nvm/manage-node.sh"
echo ""

log_info "🎯 Version management:"
echo "  List versions:         manage-node list"
echo "  Current version:       manage-node current"
echo "  Install version:       manage-node install 18.20.0"
echo "  Install LTS:           manage-node install --lts"
echo "  Switch version:        manage-node use 18"
echo "  Set default:           manage-node default 20"
echo ""

log_info "💻 NVM commands:"
echo "  nvm ls                 - List installed versions"
echo "  nvm ls-remote          - List available versions"
echo "  nvm install node       - Install latest version"
echo "  nvm install --lts      - Install latest LTS"
echo "  nvm use 18             - Switch to version 18"
echo "  nvm alias default 20   - Set default version"
echo "  nvm uninstall 16       - Remove version 16"
echo ""

log_info "📚 NPM commands:"
echo "  npm init               - Create package.json"
echo "  npm install <package>  - Install package locally"
echo "  npm install -g <pkg>   - Install globally"
echo "  npm update             - Update packages"
echo "  npm outdated           - Check for outdated packages"
echo "  npm list -g --depth=0  - List global packages"
echo ""

log_warn "⚠️  Important notes:"
echo "  • NVM modifies your shell profile (~/.bashrc or ~/.zshrc)"
echo "  • Restart terminal or run: source ~/.bashrc"
echo "  • Each Node.js version has its own global packages"
echo "  • Use .nvmrc file in projects to specify Node version"
echo "  • pm2 is installed for production process management"
echo ""

log_info "💡 Quick start:"
echo "  1. Create new project:     mkdir myapp && cd myapp"
echo "  2. Initialize:             npm init -y"
echo "  3. Install dependencies:   npm install express"
echo "  4. Create app.js and code"
echo "  5. Run with nodemon:       npx nodemon app.js"
echo "  6. Or production (pm2):    pm2 start app.js"
echo ""

log_info "🔄 Shell integration:"
if [ -f "$HOME/.bashrc" ]; then
    if grep -q 'NVM_DIR' "$HOME/.bashrc"; then
        echo "  ✅ NVM added to ~/.bashrc"
    fi
fi
if [ -f "$HOME/.zshrc" ]; then
    if grep -q 'NVM_DIR' "$HOME/.zshrc"; then
        echo "  ✅ NVM added to ~/.zshrc"
    fi
fi
echo "  To activate: source ~/.bashrc"
echo ""


