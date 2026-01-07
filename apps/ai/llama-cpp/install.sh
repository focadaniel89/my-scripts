#!/bin/bash

# ==============================================================================
# LLAMA.CPP - FLEXIBLE LLM RUNTIME
# Run any GGUF model from HuggingFace with automatic download
# OpenAI-compatible API with -hf flag support
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/os-detect.sh"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/preflight.sh"

APP_NAME="llama-cpp"
CONTAINER_NAME="llama-cpp"
DATA_DIR="/opt/ai/llama-cpp"
NETWORK="vps_network"

log_info "═══════════════════════════════════════════"
log_info "  Installing llama.cpp LLM Runtime"
log_info "═══════════════════════════════════════════"
echo ""

audit_log "INSTALL_START" "$APP_NAME"

# Pre-flight checks (models can be large)
preflight_check "$APP_NAME" 50 4 "8080"

# Check dependencies
log_step "Step 1: Checking dependencies"

# Docker check
if ! check_docker; then
    log_error "Docker is not installed"
    log_info "Please install Docker first: Infrastructure > Docker Engine"
    exit 1
fi
log_success "✓ Docker is available"

# Verify vps_network exists
if ! run_sudo docker network inspect vps_network &>/dev/null 2>&1; then
    log_error "vps_network does not exist!"
    log_error "Please install docker-engine first: ./apps/infrastructure/docker-engine/install.sh"
    exit 1
fi
log_success "✓ vps_network found"
echo ""

# Check for existing installation
if run_sudo docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_success "llama.cpp is already installed"
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

log_success "llama.cpp directories created"
echo ""

# Create Docker Compose file
log_step "Step 3: Creating Docker Compose configuration"

run_sudo tee "$DATA_DIR/docker-compose.yml" > /dev/null << 'EOF'
version: '3.8'

services:
  llama-cpp:
    image: ghcr.io/ggml-org/llama.cpp:server
    container_name: llama-cpp
    restart: unless-stopped
    
    # Internal access only (containers can reach via llama-cpp:8080)
    # Uncomment for localhost access if needed
    # ports:
    #   - "127.0.0.1:8080:8080"
    
    environment:
      - LLAMA_ARG_HOST=0.0.0.0
      - LLAMA_ARG_PORT=8080
      # Model cache directory
      - LLAMA_ARG_MODEL_CACHE=/models
      # CPU threads (adjust based on your VPS)
      - LLAMA_ARG_THREADS=4
      # Context size
      - LLAMA_ARG_CTX_SIZE=2048
      
    volumes:
      - /opt/ai/llama-cpp/models:/models
      
    networks:
      - vps_network
      
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"]
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
log_step "Step 4: Deploying llama.cpp container"
log_info "Note: Container starts without a model loaded"
log_info "You will load models on-demand using the -hf flag"
echo ""

if ! deploy_with_compose "$DATA_DIR"; then
    log_error "Failed to deploy llama.cpp"
    exit 1
fi
echo ""

# Wait for container to be ready
log_step "Step 5: Waiting for llama.cpp to be ready"
RETRIES=30
COUNT=0
while [ $COUNT -lt $RETRIES ]; do
    if run_sudo docker exec $CONTAINER_NAME curl -f http://localhost:8080/health &>/dev/null; then
        log_success "llama.cpp is ready!"
        break
    fi
    COUNT=$((COUNT + 1))
    if [ $COUNT -eq $RETRIES ]; then
        log_error "llama.cpp failed to become ready"
        run_sudo docker logs $CONTAINER_NAME --tail 50
        exit 1
    fi
    sleep 2
done
echo ""

# Display installation info
log_success "═══════════════════════════════════════════"
log_success "  llama.cpp Installation Complete!"
log_success "═══════════════════════════════════════════"
audit_log "INSTALL_COMPLETE" "$APP_NAME" "Network: $NETWORK"
echo ""

log_info "Access Information:"
echo "  Internal URL: http://llama-cpp:8080 (from containers)"
echo "  Network: $NETWORK (shared with n8n, ollama, postgres)"
echo "  OpenAI-compatible API"
echo "  NOT accessible from localhost (security by design)"
echo ""

log_info "Storage Configuration:"
echo "  Models cache: $DATA_DIR/models"
echo "  Container path: /models"
echo "  Auto-download from HuggingFace"
echo ""

log_info "Quick Start - Load Model from HuggingFace:"
echo ""
echo "  # Example 1: Mistral 7B (Q4 quantization)"
echo "  docker exec llama-cpp llama-server -hf TheBloke/Mistral-7B-Instruct-v0.2-GGUF:Q4_K_M"
echo ""
echo "  # Example 2: Llama 3.2 (auto-select best quantization)"
echo "  docker exec llama-cpp llama-server -hf ggml-org/Llama-3.2-1B-Instruct-GGUF"
echo ""
echo "  # Example 3: Gemma 2 (specific quantization)"
echo "  docker exec llama-cpp llama-server -hf ggml-org/gemma-2-2b-it-GGUF:Q5_K_M"
echo ""
echo "  # Example 4: Vision model (multimodal)"
echo "  docker exec llama-cpp llama-server -hf ggml-org/Qwen2-VL-2B-Instruct-GGUF"
echo ""

log_info "Finding Models on HuggingFace:"
echo "  1. Search: https://huggingface.co/models?library=gguf"
echo "  2. Look for repositories with '-GGUF' suffix"
echo "  3. Popular uploaders: ggml-org, TheBloke, bartowski"
echo "  4. Choose quantization: Q4_K_M (balanced), Q5_K_M (better), Q8_0 (best)"
echo ""

log_info "Using the API:"
echo ""
echo "  # From n8n HTTP Request node:"
echo "  POST http://llama-cpp:8080/v1/chat/completions"
echo "  Body:"
echo "  {"
echo "    \"model\": \"model\","
echo "    \"messages\": ["
echo "      {\"role\": \"user\", \"content\": \"Hello!\"}"
echo "    ]"
echo "  }"
echo ""
echo "  # From any container on vps_network:"
echo "  docker exec <container> curl http://llama-cpp:8080/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{"
echo "      \"model\": \"model\","
echo "      \"messages\": [{\"role\":\"user\",\"content\":\"Hello!\"}]"
echo "    }'"
echo ""

log_info "Model Recommendations:"
echo ""
echo "  Small/Fast (1-3B parameters):"
echo "    • ggml-org/Llama-3.2-1B-Instruct-GGUF"
echo "    • ggml-org/gemma-2-2b-it-GGUF"
echo "    • ggml-org/SmolVLM-Instruct-GGUF (vision)"
echo ""
echo "  Balanced (7B parameters):"
echo "    • TheBloke/Mistral-7B-Instruct-v0.2-GGUF"
echo "    • ggml-org/Qwen2.5-7B-Instruct-GGUF"
echo "    • bartowski/Llama-3.1-8B-Instruct-GGUF"
echo ""
echo "  Code Generation:"
echo "    • bartowski/DeepSeek-Coder-V2-Lite-Instruct-GGUF"
echo "    • ggml-org/CodeLlama-7B-Instruct-GGUF"
echo ""
echo "  Vision/Multimodal:"
echo "    • ggml-org/Qwen2-VL-2B-Instruct-GGUF"
echo "    • ggml-org/Qwen2-VL-7B-Instruct-GGUF"
echo ""

log_info "Quantization Guide:"
echo "  Q2_K   - Smallest, lowest quality (2-3 bits)"
echo "  Q3_K_M - Very small, decent quality (3 bits)"
echo "  Q4_K_M - ⭐ Recommended (4 bits, balanced)"
echo "  Q5_K_M - Better quality (5 bits)"
echo "  Q6_K   - High quality (6 bits)"
echo "  Q8_0   - Highest quality (8 bits, larger)"
echo ""

log_info "Docker Management:"
echo "  View logs:           docker logs $CONTAINER_NAME -f"
echo "  Restart container:   docker restart $CONTAINER_NAME"
echo "  Stop container:      docker stop $CONTAINER_NAME"
echo "  Start container:     docker start $CONTAINER_NAME"
echo "  Remove:              cd $DATA_DIR && docker-compose down"
echo "  List cached models:  ls -lh $DATA_DIR/models"
echo ""

log_info "Advanced Configuration:"
echo "  # More CPU threads (faster inference)"
echo "  docker exec llama-cpp llama-server -hf <model> -t 8"
echo ""
echo "  # Larger context window"
echo "  docker exec llama-cpp llama-server -hf <model> -c 4096"
echo ""
echo "  # Multiple parallel requests"
echo "  docker exec llama-cpp llama-server -hf <model> -np 4"
echo ""

log_info "Integration with n8n:"
echo "  1. Use HTTP Request node"
echo "  2. URL: http://llama-cpp:8080/v1/chat/completions"
echo "  3. Method: POST"
echo "  4. Headers: Content-Type: application/json"
echo "  5. Body: OpenAI-compatible format (see examples above)"
echo ""

log_info "Memory Requirements:"
echo "  • 1-3B models (Q4):  ~2-4 GB RAM"
echo "  • 7B models (Q4):    ~4-6 GB RAM"
echo "  • 13B models (Q4):   ~8-10 GB RAM"
echo "  Current system RAM: $(free -h | awk '/^Mem:/ {print $2}')"
echo ""

log_info "Security Notes:"
echo "  • Internal network access only (vps_network)"
echo "  • NOT exposed to localhost or internet"
echo "  • Only containers on $NETWORK can connect"
echo "  • Secure by design (n8n, ollama, postgres access only)"
echo ""

log_info "Troubleshooting:"
echo "  # Check if server is running"
echo "  docker exec llama-cpp curl -f http://localhost:8080/health"
echo ""
echo "  # View server logs"
echo "  docker logs llama-cpp --tail 100"
echo ""
echo "  # Test with simple completion"
echo "  docker exec llama-cpp llama-cli -hf ggml-org/gemma-3-1b-it-GGUF -p 'Hello'"
echo ""

log_info "Documentation:"
echo "  • Official docs: https://github.com/ggerganov/llama.cpp"
echo "  • API reference: https://github.com/ggerganov/llama.cpp/blob/master/examples/server/README.md"
echo "  • HuggingFace GGUF models: https://huggingface.co/models?library=gguf"
echo ""

log_info "Next Steps:"
echo "  1. Find a model on HuggingFace (search for 'GGUF')"
echo "  2. Load it with: docker exec llama-cpp llama-server -hf <user>/<model>:Q4_K_M"
echo "  3. Use API at http://llama-cpp:8080 (from n8n/containers)"
echo "  4. Models auto-cache in $DATA_DIR/models"
echo ""
