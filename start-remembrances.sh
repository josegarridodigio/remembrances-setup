#!/bin/bash

# Script directory (where remembrances-mcp is installed)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} ✓ $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} ⚠ $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} ✗ $1" >&2; }
log_step() { echo -e "${BLUE}[STEP]${NC} ➜ $1" >&2; }

# Check Docker
command -v docker &> /dev/null || { log_error "Docker is not installed"; exit 1; }

# Check GPU availability and Docker GPU support
has_gpu() {
    # Check if nvidia-smi exists and GPU is available
    if command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
        # Check if nvidia-container-toolkit is installed
        if docker info 2>/dev/null | grep -q "Runtimes.*nvidia" || \
           command -v nvidia-container-cli &> /dev/null; then
            log_info "NVIDIA GPU and Docker GPU support detected"
            return 0
        else
            log_warn "NVIDIA GPU detected but Docker GPU support (nvidia-container-toolkit) not available"
            log_warn "Install nvidia-container-toolkit for GPU support"
            log_warn "See: https://hub.docker.com/r/ollama/ollama#nvidia-gpu"
            return 1
        fi
    fi
    return 1
}

# Ollama container management
OLLAMA_CONTAINER="ollama"
OLLAMA_IMAGE="ollama/ollama:latest"

# Required models to pull and verify
REQUIRED_MODELS=(
    "nomic-embed-text:latest"
    "hf.co/limcheekin/CodeRankEmbed-GGUF:Q4_K_M"
)

# Function to ensure all required models are available
ensure_models() {
    log_step "Verifying required models..."
    MODELS=$(docker exec ${OLLAMA_CONTAINER} ollama list 2>/dev/null)
    
    for model in "${REQUIRED_MODELS[@]}"; do
        # Extract the model name without version tag for matching
        model_name=$(echo "${model}" | sed 's/:.*$//')
        
        if ! echo "$MODELS" | grep -qi "${model_name}"; then
            log_warn "Model ${model} not found, pulling..."
            if ! docker exec ${OLLAMA_CONTAINER} ollama pull "${model}"; then
                log_error "Failed to pull model ${model}"
                return 1
            fi
        fi
    done
    
    log_info "All models ready"
}

# Check if container exists
if ! docker ps -a --format '{{.Names}}' | grep -q "^${OLLAMA_CONTAINER}$"; then
    log_step "Ollama container not found, creating new container..."
    
    # Pull latest image
    log_info "Pulling latest Ollama image: ${OLLAMA_IMAGE}"
    if ! docker pull ${OLLAMA_IMAGE} > /dev/null 2>&1; then
        log_error "Failed to pull Ollama image"
        exit 1
    fi
    
    # Create container with or without GPU support
    if has_gpu; then
        log_info "NVIDIA GPU detected - creating container with GPU support"
        log_info "Reference: https://hub.docker.com/r/ollama/ollama#nvidia-gpu"
        if ! docker run -d --gpus all --name ${OLLAMA_CONTAINER} -p 11434:11434 -v ollama:/root/.ollama ${OLLAMA_IMAGE} > /dev/null; then
            log_error "Failed to create container with GPU support"
            exit 1
        fi
    else
        log_info "No GPU detected - creating CPU-only container"
        if ! docker run -d --name ${OLLAMA_CONTAINER} -p 11434:11434 -v ollama:/root/.ollama ${OLLAMA_IMAGE} > /dev/null; then
            log_error "Failed to create container"
            exit 1
        fi
    fi
    
    # Pull required models
    ensure_models
    
    log_info "Container setup completed successfully"
else
    # Container exists, check if it needs to be updated
    log_info "Checking for Ollama updates..."
    
    # Get current image ID
    CURRENT_IMAGE=$(docker inspect --format='{{.Image}}' ${OLLAMA_CONTAINER} 2>/dev/null)
    
    # Pull latest image silently
    docker pull ${OLLAMA_IMAGE} > /dev/null 2>&1
    
    # Get new image ID
    NEW_IMAGE=$(docker inspect --format='{{.Id}}' ${OLLAMA_IMAGE} 2>/dev/null)
    
    # If images differ, recreate container
    if [ "$CURRENT_IMAGE" != "$NEW_IMAGE" ]; then
        log_warn "New Ollama version available, updating container..."
        
        # Stop and remove old container
        docker stop ${OLLAMA_CONTAINER} &> /dev/null
        docker rm ${OLLAMA_CONTAINER} &> /dev/null
        
        # Create new container
        if has_gpu; then
            log_info "Recreating container with GPU support"
            docker run -d --gpus all --name ${OLLAMA_CONTAINER} -p 11434:11434 -v ollama:/root/.ollama ${OLLAMA_IMAGE} > /dev/null
        else
            log_info "Recreating CPU-only container"
            docker run -d --name ${OLLAMA_CONTAINER} -p 11434:11434 -v ollama:/root/.ollama ${OLLAMA_IMAGE} > /dev/null
        fi
    fi
fi

# Start container if not running
if ! docker ps --format '{{.Names}}' | grep -q "^${OLLAMA_CONTAINER}$"; then
    log_info "Starting Ollama container..."
    if ! docker start ${OLLAMA_CONTAINER} > /dev/null; then
        log_error "Failed to start Ollama container"
        exit 1
    fi
fi

# Wait for Ollama API to be ready
log_step "Waiting for Ollama API..."
for i in {1..15}; do
    if curl -s http://localhost:11434/api/tags > /dev/null 2>&1; then
        log_info "Ollama API is ready"
        break
    fi
    if [ $i -eq 15 ]; then
        log_error "Ollama API failed to respond after 30 seconds"
        exit 1
    fi
    sleep 2
done

# Verify required models are available
if ! ensure_models; then
    log_error "Failed to ensure all models are available"
    exit 1
fi

# Check if remembrances-mcp binary exists
if [ ! -f "$SCRIPT_DIR/remembrances-mcp" ]; then
    log_error "remembrances-mcp binary not found at $SCRIPT_DIR/remembrances-mcp"
    exit 1
fi

if [ ! -x "$SCRIPT_DIR/remembrances-mcp" ]; then
    log_error "remembrances-mcp binary is not executable"
    log_info "Run: chmod +x $SCRIPT_DIR/remembrances-mcp"
    exit 1
fi

# Execute remembrances-mcp
log_step "Starting remembrances-mcp..."

# Set LD_LIBRARY_PATH to include the lib directory
export LD_LIBRARY_PATH="$SCRIPT_DIR/lib:${LD_LIBRARY_PATH:-}"

exec "$SCRIPT_DIR/remembrances-mcp" --config "$SCRIPT_DIR/config.yaml" "$@"