#!/bin/bash
# Unified development startup script for Nexus Agents

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse command line arguments
READ_ONLY=false
if [ "$1" = "--read-only" ]; then
    READ_ONLY=true
    echo -e "${GREEN}Starting Nexus Agents Development Environment (Read-Only Mode)...${NC}"
    echo -e "${YELLOW}This mode starts PostgreSQL, API backend, and Web UI${NC}"
    echo -e "${YELLOW}No Redis, worker, or MCP servers - you can view imported data but not create new tasks${NC}"
else
    echo -e "${GREEN}Starting Nexus Agents Development Environment...${NC}"
fi

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check if a port is in use
port_in_use() {
    lsof -i:$1 >/dev/null 2>&1
}

# Function to wait for a service to be ready
wait_for_service() {
    local service_name=$1
    local check_command=$2
    local max_attempts=30
    local attempt=0
    
    echo -n "Waiting for $service_name to be ready..."
    while [ $attempt -lt $max_attempts ]; do
        if eval $check_command; then
            echo -e " ${GREEN}Ready!${NC}"
            return 0
        fi
        echo -n "."
        sleep 1
        attempt=$((attempt + 1))
    done
    echo -e " ${RED}Failed!${NC}"
    return 1
}

# Check for required commands
echo "Checking prerequisites..."
if ! command_exists redis-server && ! command_exists docker; then
    echo -e "${RED}Error: Neither redis-server nor docker is installed.${NC}"
    echo "Please install Redis or Docker to continue."
    exit 1
fi

if ! command_exists uv; then
    echo -e "${RED}Error: uv is not installed.${NC}"
    echo "Please install uv: https://github.com/astral-sh/uv"
    exit 1
fi

# Load environment variables
if [ -f .env ]; then
    echo "Loading environment variables from .env..."
    # Properly handle .env file - skip comments and empty lines
    set -a  # automatically export all variables
    source <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env)
    set +a
else
    echo -e "${YELLOW}Warning: .env file not found. Using default values.${NC}"
fi

# Start Redis (skip in frontend-only mode)
echo -e "\n${YELLOW}Starting database services...${NC}"
REDIS_STARTED=false
if [ "$READ_ONLY" = true ]; then
    echo -e "${YELLOW}Skipping Redis startup (read-only mode)${NC}"
    # Start only PostgreSQL
    if command_exists docker && docker info >/dev/null 2>&1; then
        if docker compose ps postgres | grep -q "running"; then
            echo "PostgreSQL container already running"
        else
            echo "Starting PostgreSQL using Docker Compose..."
            docker compose up -d postgres >/dev/null 2>&1
        fi
    else
        echo -e "${YELLOW}Warning: PostgreSQL not found. Please ensure it's running manually.${NC}"
    fi
else
    # Full mode - start both Redis and PostgreSQL
    if command_exists docker && docker info >/dev/null 2>&1; then
        if docker compose ps redis | grep -q "running"; then
            echo "Redis container already running"
            REDIS_STARTED=true
        else
            echo "Starting Redis and PostgreSQL using Docker Compose..."
            docker compose up -d redis postgres >/dev/null 2>&1
            REDIS_STARTED=true
        fi
    elif command_exists redis-server; then
        # Test if Redis is actually functional, not just port availability
        if redis-cli ping >/dev/null 2>&1; then
            echo "Redis already running and responding"
            REDIS_STARTED=true
        else
            echo "Starting local Redis server..."
            redis-server --daemonize yes
            REDIS_STARTED=true
        fi
    elif redis-cli ping >/dev/null 2>&1; then
        echo "Redis already running and responding"
        REDIS_STARTED=true
    else
        echo -e "${RED}Error: Redis is required but not available.${NC}"
        echo -e "${YELLOW}Please install Redis using one of these methods:${NC}"
        echo "  1. Install Docker Desktop and ensure it's running"
        echo "  2. Install Redis locally:"
        echo "     - macOS: brew install redis"
        echo "     - Ubuntu/Debian: sudo apt-get install redis-server"
        echo "     - Other: https://redis.io/download"
        exit 1
    fi

    # Wait for Redis to be ready
    if [ "$REDIS_STARTED" = true ]; then
        wait_for_service "Redis" "redis-cli ping >/dev/null 2>&1"
    fi
fi

# Setup MCP servers if needed (skip in read-only mode)
if [ "$READ_ONLY" = false ]; then
    echo -e "\n${YELLOW}Checking MCP servers...${NC}"
    if [ ! -d "external_mcp_servers/firecrawl-mcp" ] || [ ! -d "external_mcp_servers/exa-mcp" ]; then
        echo "MCP servers not found. Running setup script..."
        ./scripts/setup_mcp_servers.sh
    else
        echo "MCP servers already set up"
    fi

    # Validate MCP setup
    echo -e "\n${YELLOW}Validating MCP setup...${NC}"
    uv run python scripts/validate_mcp_setup.py || {
        echo -e "${YELLOW}Warning: MCP validation failed. Some features may not work.${NC}"
    }
else
    echo -e "\n${YELLOW}Skipping MCP servers setup (read-only mode)${NC}"
fi

# Create necessary directories
echo -e "\n${YELLOW}Creating necessary directories...${NC}"
mkdir -p data logs output

# Kill any existing processes on our ports
echo -e "\n${YELLOW}Checking for existing processes...${NC}"
if port_in_use 12000; then
    echo "Killing existing process on port 12000..."
    lsof -ti:12000 | xargs kill -9 2>/dev/null || true
fi
if port_in_use 12001; then
    echo "Killing existing process on port 12001..."
    lsof -ti:12001 | xargs kill -9 2>/dev/null || true
fi

# Start API backend
echo -e "\n${YELLOW}Starting API backend on port 12000...${NC}"
uv run python api.py > logs/api.log 2>&1 &
API_PID=$!
echo "API backend PID: $API_PID"

# Wait for API to be ready
wait_for_service "API backend" "curl -s http://localhost:12000/docs >/dev/null 2>&1"

# Start worker process (skip in read-only mode)
if [ "$READ_ONLY" = false ]; then
    echo -e "\n${YELLOW}Starting background worker...${NC}"
    uv run python -m src.worker > logs/worker.log 2>&1 &
    WORKER_PID=$!
    echo "Worker PID: $WORKER_PID"
else
    echo -e "\n${YELLOW}Skipping background worker (read-only mode)${NC}"
    WORKER_PID=""
fi

# Start Web UI
echo -e "\n${YELLOW}Starting Web UI on port 12001...${NC}"
cd web && uv run python server.py > ../logs/web.log 2>&1 &
WEB_PID=$!
echo "Web UI PID: $WEB_PID"

# Wait for Web UI to be ready
wait_for_service "Web UI" "curl -s http://localhost:12001 >/dev/null 2>&1"

# Create PID file for cleanup
echo "API_PID=$API_PID" > .dev_pids
if [ "$WORKER_PID" != "" ]; then
    echo "WORKER_PID=$WORKER_PID" >> .dev_pids
fi
echo "WEB_PID=$WEB_PID" >> .dev_pids

# Success message
if [ "$READ_ONLY" = true ]; then
    echo -e "\n${GREEN}✅ Read-only development services started successfully!${NC}"
    echo -e "\n${GREEN}Services running:${NC}"
    echo "  - PostgreSQL: localhost:5432"
    echo "  - API Backend: http://localhost:12000"
    echo "  - API Docs: http://localhost:12000/docs"
    echo "  - Web UI: http://localhost:12001"
    echo -e "\n${YELLOW}Logs:${NC}"
    echo "  - API: logs/api.log"
    echo "  - Web UI: logs/web.log"
    echo -e "\n${GREEN}Perfect for viewing imported data and frontend development!${NC}"
    echo -e "${YELLOW}Note: Import your database with 'python scripts/import_data.py' for realistic data${NC}"
else
    echo -e "\n${GREEN}✅ All services started successfully!${NC}"
    echo -e "\n${GREEN}Services running:${NC}"
    echo "  - Redis: localhost:6379"
    echo "  - PostgreSQL: localhost:5432"
    echo "  - API Backend: http://localhost:12000"
    echo "  - API Docs: http://localhost:12000/docs"
    echo "  - Worker: Processing tasks in background"
    echo "  - Web UI: http://localhost:12001"
    echo -e "\n${YELLOW}Logs:${NC}"
    echo "  - API: logs/api.log"
    echo "  - Worker: logs/worker.log"
    echo "  - Web UI: logs/web.log"
fi
echo -e "\n${YELLOW}To stop all services, run:${NC} ./scripts/stop_dev.sh"

# Keep script running and show logs
echo -e "\n${YELLOW}Following logs (Ctrl+C to exit)...${NC}"
# Wait a moment for log files to be created and ensure they exist
sleep 2
touch logs/api.log logs/worker.log logs/web.log 2>/dev/null || true
tail -f logs/api.log logs/worker.log logs/web.log
