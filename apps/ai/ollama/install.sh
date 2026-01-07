#!/bin/bash

# ==============================================================================
# OLLAMA - LOCAL LLM RUNTIME
# Self-hosted large language models (Llama, Mistral, CodeLlama, etc.)
# Docker deployment for internal network access only
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/preflight.sh"

APP_NAME="ollama"
CONTAINER_NAME="ollama"
DATA_DIR="/opt/ai/ollama"
NETWORK="vps_network"

log_info "═══════════════════════════════════════════"
log_info "  Installing Ollama LLM Runtime"
log_info "═══════════════════════════════════════════"
echo ""

audit_log "INSTALL_START" "$APP_NAME"

# Pre-flight checks (Ollama models can be large)
preflight_check "$APP_NAME" 50 4 "11434"

# Check dependencies
log_step "Step 1: Checking dependencies"

# Docker check
if ! check_docker; then
    log_error "Docker is not installed"
    log_info "Please install Docker first: Infrastructure > Docker Engine"
    exit 1
fi
log_success "✓ Docker is available"
echo ""

# Check for existing installation
if run_sudo docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_success "Ollama is already installed"
    if confirm_action "Reinstall?"; then
        log_info "Removing existing installation..."
        run_sudo docker stop "$CONTAINER_NAME" 2>/dev/null || true
        run_sudo docker rm "$CONTAINER_NAME" 2>/dev/null || true
    else
        log_info "Installation cancelled"
        exit 0
    fi
fi
echo ""

# Setup directories
log_step "Step 2: Setting up directories"
create_app_directory "$DATA_DIR"
create_app_directory "$DATA_DIR/models"

log_success "Ollama directories created"
echo ""

# Create Docker network
log_step "Step 3: Creating Docker network"
create_docker_network "$NETWORK"
echo ""

# Create Docker Compose file
log_step "Step 4: Creating Docker Compose configuration"

run_sudo tee "$DATA_DIR/docker-compose.yml" > /dev/null << 'EOF'
version: '3.8'

services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    
    # Internal access only (containers can reach via ollama:11434)
    # Optional: Uncomment for localhost access
    # ports:
    #   - "127.0.0.1:11434:11434"
    
    environment:
      - OLLAMA_MODELS=/root/.ollama/models
      - OLLAMA_HOST=0.0.0.0:11434
      
    volumes:
      - /opt/ai/ollama/models:/root/.ollama/models
      
    networks:
      - vps_network
      
    healthcheck:
      test: ["CMD-SHELL", "ollama list || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

networks:
  vps_network:
    external: true
EOF

log_success "Docker Compose configuration created"
echo ""

# Deploy container
log_step "Step 5: Deploying Ollama container"
if ! deploy_with_compose "$DATA_DIR"; then
    log_error "Failed to deploy Ollama"
    exit 1
fi
echo ""

# Wait for container to be ready
log_step "Step 6: Waiting for Ollama to be ready"
RETRIES=30
COUNT=0
while [ $COUNT -lt $RETRIES ]; do
    if run_sudo docker exec $CONTAINER_NAME ollama list &>/dev/null; then
        log_success "Ollama is ready!"
        break
    fi
    COUNT=$((COUNT + 1))
    if [ $COUNT -eq $RETRIES ]; then
        log_error "Ollama failed to become ready"
        run_sudo docker logs $CONTAINER_NAME --tail 50
        exit 1
    fi
    sleep 2
done
echo ""

# Download default model (gemma3)
log_step "Step 7: Downloading default model (gemma3)"
log_info "Downloading gemma3 model (this may take a few minutes)..."
if run_sudo docker exec $CONTAINER_NAME ollama pull gemma3; then
    log_success "gemma3 model downloaded successfully"
else
    log_warn "Failed to download gemma3, you can download it later manually"
    log_info "Command: docker exec ollama ollama pull gemma3"
fi
echo ""

# Display installation info
log_success "═══════════════════════════════════════════"
log_success "  Ollama Installation Complete!"
log_success "═══════════════════════════════════════════"
audit_log "INSTALL_COMPLETE" "$APP_NAME" "Network: $NETWORK (internal only)"
echo ""

log_info "Default Model:"
echo "  gemma3: Downloaded and ready to use"
echo ""

log_info "Access Information:"
echo "  Internal URL: http://ollama:11434 (from containers)"
echo "  Network: $NETWORK"
echo "  Not accessible from internet (security by design)"
echo ""

log_info "Storage Configuration:"
echo "  Models directory: $DATA_DIR/models"
echo "  Container path: /root/.ollama/models"
echo "  Volume mount: Persistent storage"
echo ""

log_info "Docker Management:"
echo "  View logs:      docker logs $CONTAINER_NAME -f"
echo "  List models:    docker exec $CONTAINER_NAME ollama list"
echo "  Pull model:     docker exec $CONTAINER_NAME ollama pull llama2"
echo "  Run model:      docker exec $CONTAINER_NAME ollama run llama2"
echo "  Restart:        docker restart $CONTAINER_NAME"
echo "  Stop:           docker stop $CONTAINER_NAME"
echo "  Start:          docker start $CONTAINER_NAME"
echo "  Remove:         cd $DATA_DIR && docker-compose down"
echo ""

log_info "Quick Start - Download More Models:"
echo "  # Llama 2 (7B) - General purpose"
echo "  docker exec ollama ollama pull llama2"
echo ""
echo "  # Llama 2 (13B) - Better quality (requires more RAM)"
echo "  docker exec ollama ollama pull llama2:13b"
echo ""
echo "  # Mistral (7B) - Fast and efficient"
echo "  docker exec ollama ollama pull mistral"
echo ""
echo "  # CodeLlama (7B) - Code generation"
echo "  docker exec ollama ollama pull codellama"
echo ""
echo "  # Phi-2 (2.7B) - Small and fast"
echo "  docker exec ollama ollama pull phi"
echo ""

log_info "Integration Examples:"
echo ""
echo "  # From n8n workflow (HTTP Request node):"
echo "  POST http://ollama:11434/api/generate"
echo "  Body: {\"model\": \"gemma3\", \"prompt\": \"Hello!\"}"
echo ""
echo "  # From Python container:"
echo "  import requests"
echo "  response = requests.post('http://ollama:11434/api/generate',"
echo "      json={'model': 'gemma3', 'prompt': 'Hello!'})"
echo ""
echo "  # Test from VPS terminal:"
echo "  docker exec ollama ollama run gemma3 \"Write a haiku about Docker\""
echo ""

log_info "Recommended Models by Use Case:"
echo "  - General chat: gemma3 (installed), llama2, mistral"
echo "  - Code generation: codellama, deepseek-coder"
echo "  - Small/Fast: phi, tinyllama"
echo "  - Multilingual: aya, qwen"
echo "  - Vision: llava (image understanding)"
echo ""

log_info "Model Management:"
echo "  List all models:     docker exec ollama ollama list"
echo "  Remove model:        docker exec ollama ollama rm <model>"
echo "  Show model info:     docker exec ollama ollama show <model>"
echo "  Update model:        docker exec ollama ollama pull <model>"
echo ""

log_info "Memory Requirements:"
echo "  - 7B models: ~4-6 GB RAM"
echo "  - 13B models: ~8-10 GB RAM"
echo "  - 70B models: ~40+ GB RAM"
echo "  Current system RAM: $(free -h | awk '/^Mem:/ {print $2}')"
echo ""

log_info "Security Notes:"
echo "  No external ports exposed"
echo "  Access only via Docker network ($NETWORK)"
echo "  Containers on same network can connect"
echo "  Not accessible from internet"
echo ""

log_info "Containers with Access:"
echo "  - n8n (if installed)"
echo "  - Any container on $NETWORK"
echo ""

log_info "Documentation:"
echo "  - Official docs: https://ollama.ai/docs"
echo "  - Model library: https://ollama.ai/library"
echo "  - API reference: https://github.com/ollama/ollama/blob/main/docs/api.md"
echo ""

log_info "First Steps:"
echo "  1. Test installed model: docker exec ollama ollama run gemma3 'Hello!'"
echo "  2. Use from n8n/other containers via http://ollama:11434"
echo "  3. Download more models: docker exec ollama ollama pull llama2"
echo ""
