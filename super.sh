#!/bin/bash
set -euo pipefail

# super.sh - Podman FastAPI OpenResty Orchestration Script
# Usage: ./super.sh [init|start|stop|restart|status|logs]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Only load environment variables for commands other than init
if [ "${1:-}" != "init" ]; then
    # Load environment variables
    if [ -f "$ROOT_DIR/.env" ]; then
        while IFS='=' read -r key value; do
            case "$key" in
            APP | DOMAIN | EMAIL | POSTGRES_DB | POSTGRES_USER | POSTGRES_PASSWORD | REDIS_PASSWORD | JWT_SECRET)
                export "$key"="$value"
                ;;
            esac
        done < <(grep -E '^(APP|DOMAIN|EMAIL|POSTGRES_DB|POSTGRES_USER|POSTGRES_PASSWORD|REDIS_PASSWORD|JWT_SECRET)=' "$ROOT_DIR/.env")
    else
        echo "Error: .env file not found in $ROOT_DIR" >&2
        exit 1
    fi

    # Require essential secrets
    : "${POSTGRES_PASSWORD:?Environment variable POSTGRES_PASSWORD must be set and non-empty}"
    : "${REDIS_PASSWORD:?Environment variable REDIS_PASSWORD must be set and non-empty}"
    : "${JWT_SECRET:?Environment variable JWT_SECRET must be set and non-empty}"
fi

# Default values
APP="${APP:-belomtau}"
DOMAIN="${DOMAIN:-example.com}"
EMAIL="${EMAIL:-admin@example.com}"
POSTGRES_DB="${POSTGRES_DB:-fastapi_db}"
POSTGRES_USER="${POSTGRES_USER:-fastapi_user}"

# Container names
POD_NAME="${APP}_pod"
NETWORK_NAME="app-net"
POSTGRES_CONTAINER="${APP}_postgres"
REDIS_CONTAINER="${APP}_redis"
FASTAPI_CONTAINER="${APP}_fastapi"
OPENRESTY_CONTAINER="${APP}_openresty"
# CERTBOT_CONTAINER="${APP}_certbot"
HELPER_CONTAINER="${APP}_helper"
PGADMIN_CONTAINER="${APP}_pgadmin"

# Directories
DATA_DIR="$ROOT_DIR/data"
CONF_DIR="$ROOT_DIR/conf"
CERTS_DIR="$ROOT_DIR/certs"
LOGS_DIR="$ROOT_DIR/logs"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

# Initialize directory structure
init_directories() {
    log "Initializing directory structure..."

    mkdir -p "$DATA_DIR"/{postgres,redis}
    mkdir -p "$CONF_DIR"/{openresty,fastapi}
    mkdir -p "$CONF_DIR/openresty/lua"
    mkdir -p "$CERTS_DIR/letsencrypt"
    mkdir -p "$LOGS_DIR"

    # Create OpenResty nginx.conf if it doesn't exist
    if [ ! -f "$CONF_DIR/openresty/nginx.conf" ]; then
        cat >"$CONF_DIR/openresty/nginx.conf" <<'EOF'
events {
    worker_connections 1024;
}

http {
    include       /usr/local/openresty/nginx/conf/mime.types;
    default_type  application/octet-stream;

    # Logging
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;

    # Basic settings
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/xml+rss application/json;

    # Rate limiting
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;

    # Upstream FastAPI
    upstream fastapi_backend {
        server belomtau_fastapi:8000;
        keepalive 32;
    }

    # HTTP to HTTPS redirect
    server {
        listen 80;
        server_name _;

        # Let's Encrypt challenge
        location /.well-known/acme-challenge/ {
            root /var/www/certbot;
        }

        location / {
            return 301 https://$host$request_uri;
        }
    }

    # HTTPS server
    server {
        listen 443 ssl http2;
        server_name DOMAIN_PLACEHOLDER;

        # SSL configuration
        ssl_certificate /etc/letsencrypt/live/DOMAIN_PLACEHOLDER/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/DOMAIN_PLACEHOLDER/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA384;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 10m;

        # Security headers
        add_header X-Frame-Options DENY;
        add_header X-Content-Type-Options nosniff;
        add_header X-XSS-Protection "1; mode=block";
        add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload";

        # Rate limiting
        limit_req zone=api burst=20 nodelay;

        # Health check endpoint (no auth required)
        location /healthz {
            proxy_pass http://fastapi_backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        # API endpoints with JWT verification
        location / {
            access_by_lua_file /usr/local/openresty/lua/verify.lua;

            proxy_pass http://fastapi_backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header Authorization $http_authorization;

            # Connection settings
            proxy_connect_timeout 30s;
            proxy_send_timeout 30s;
            proxy_read_timeout 30s;
            proxy_buffering off;
        }
    }
}
EOF
        sed -i "s/DOMAIN_PLACEHOLDER/$DOMAIN/g" "$CONF_DIR/openresty/nginx.conf"
        log "Created OpenResty nginx.conf"
    fi

    # Create Lua JWT verification script
    if [ ! -f "$CONF_DIR/openresty/lua/verify.lua" ]; then
        cat >"$CONF_DIR/openresty/lua/verify.lua" <<'EOF'
local jwt = require "resty.jwt"
local redis = require "resty.redis"

-- Get JWT secret from environment
local jwt_secret = os.getenv("JWT_SECRET") or "your-secret-key"

-- Get Authorization header
local auth_header = ngx.var.http_authorization
if not auth_header then
    ngx.log(ngx.ERR, "No Authorization header found")
    ngx.status = 401
    ngx.say('{"error": "Authorization header required"}')
    ngx.exit(401)
end

-- Extract token from Bearer header
local token = string.match(auth_header, "Bearer%s+(.+)")
if not token then
    ngx.log(ngx.ERR, "Invalid Authorization header format")
    ngx.status = 401
    ngx.say('{"error": "Invalid Authorization header format"}')
    ngx.exit(401)
end

-- Verify JWT token
local jwt_obj = jwt:verify(jwt_secret, token)
if not jwt_obj.valid then
    ngx.log(ngx.ERR, "Invalid JWT token: ", jwt_obj.reason)
    ngx.status = 401
    ngx.say('{"error": "Invalid token"}')
    ngx.exit(401)
end

-- Optional: Check if token is blacklisted in Redis
local red = redis:new()
red:set_timeout(1000) -- 1 second

local ok, err = red:connect("belomtau_redis", 6379)
if ok then
    local res, err = red:auth(os.getenv("REDIS_PASSWORD") or "changeme")
    if res then
        local blacklisted = red:get("blacklist:" .. token)
        if blacklisted and blacklisted ~= ngx.null then
            ngx.log(ngx.ERR, "Token is blacklisted")
            ngx.status = 401
            ngx.say('{"error": "Token revoked"}')
            ngx.exit(401)
        end
    end
    red:close()
end

-- Set user info in headers for FastAPI
if jwt_obj.payload.sub then
    ngx.req.set_header("X-User-ID", jwt_obj.payload.sub)
end
if jwt_obj.payload.email then
    ngx.req.set_header("X-User-Email", jwt_obj.payload.email)
end

ngx.log(ngx.INFO, "JWT verification successful for user: ", jwt_obj.payload.sub or "unknown")
EOF
        log "Created Lua JWT verification script"
    fi

    # Create FastAPI configuration
    if [ ! -f "$CONF_DIR/fastapi/config.py" ]; then
        cat >"$CONF_DIR/fastapi/config.py" <<'EOF'
import os
from pydantic import BaseSettings

class Settings(BaseSettings):
    # Database
    DATABASE_URL: str = os.getenv("DATABASE_URL", "postgresql://fastapi_user:changeme@belomtau_postgres:5432/fastapi_db")

    # Redis
    REDIS_URL: str = os.getenv("REDIS_URL", "redis://:changeme@belomtau_redis:6379/0")

    # JWT
    JWT_SECRET: str = os.getenv("JWT_SECRET", "your-secret-key")
    JWT_ALGORITHM: str = "HS256"
    JWT_EXPIRE_MINUTES: int = 60 * 24 * 7  # 7 days

    # App
    APP_NAME: str = "FastAPI App"
    DEBUG: bool = os.getenv("DEBUG", "false").lower() == "true"

    class Config:
        env_file = ".env"

settings = Settings()
EOF
        log "Created FastAPI configuration"
    fi
}

# Create network if it doesn't exist
create_network() {
    if ! podman network exists "$NETWORK_NAME" 2>/dev/null; then
        log "Creating network: $NETWORK_NAME"
        podman network create "$NETWORK_NAME"
    else
        info "Network $NETWORK_NAME already exists"
    fi
}

# Create pod if it doesn't exist
create_pod() {
    if ! podman pod exists "$POD_NAME" 2>/dev/null; then
        log "Creating pod: $POD_NAME"
        podman pod create \
            --name "$POD_NAME" \
            --network "$NETWORK_NAME" \
            --publish 80:80 \
            --publish 443:443 \
            --publish 127.0.0.1:5432:5432 \
            --publish 127.0.0.1:6379:6379 \
            --publish 8080:8080
    else
        info "Pod $POD_NAME already exists"
    fi
}

# Start PostgreSQL container
start_postgres() {
    if ! podman container exists "$POSTGRES_CONTAINER" 2>/dev/null; then
        log "Starting PostgreSQL container..."
        podman run -d \
            --name "$POSTGRES_CONTAINER" \
            --pod "$POD_NAME" \
            --env POSTGRES_DB="$POSTGRES_DB" \
            --env POSTGRES_USER="$POSTGRES_USER" \
            --env POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
            --volume "$DATA_DIR/postgres:/var/lib/postgresql/data:Z" \
            --health-cmd="pg_isready -U $POSTGRES_USER -d $POSTGRES_DB" \
            --health-interval=10s \
            --health-timeout=5s \
            --health-retries=5 \
            docker.io/postgres:15-alpine
    else
        info "PostgreSQL container already exists"
        if [ "$(podman container inspect "$POSTGRES_CONTAINER" --format '{{.State.Status}}')" != "running" ]; then
            log "Starting existing PostgreSQL container..."
            podman start "$POSTGRES_CONTAINER"
        fi
    fi
}

# Start Redis container
start_redis() {
    if ! podman container exists "$REDIS_CONTAINER" 2>/dev/null; then
        log "Starting Redis container..."
        podman run -d \
            --name "$REDIS_CONTAINER" \
            --pod "$POD_NAME" \
            --volume "$DATA_DIR/redis:/data:Z" \
            --health-cmd="redis-cli --no-auth-warning auth $REDIS_PASSWORD ping" \
            --health-interval=10s \
            --health-timeout=5s \
            --health-retries=5 \
            docker.io/redis:7-alpine \
            redis-server --requirepass "$REDIS_PASSWORD" --appendonly yes
    else
        info "Redis container already exists"
        if [ "$(podman container inspect "$REDIS_CONTAINER" --format '{{.State.Status}}')" != "running" ]; then
            log "Starting existing Redis container..."
            podman start "$REDIS_CONTAINER"
        fi
    fi
}

# Start FastAPI container
start_fastapi() {
    if ! podman container exists "$FASTAPI_CONTAINER" 2>/dev/null; then
        log "Starting FastAPI container..."
        podman run -d \
            --name "$FASTAPI_CONTAINER" \
            --pod "$POD_NAME" \
            --env DATABASE_URL="postgresql://$POSTGRES_USER:$POSTGRES_PASSWORD@localhost:5432/$POSTGRES_DB" \
            --env REDIS_URL="redis://:$REDIS_PASSWORD@localhost:6379/0" \
            --env JWT_SECRET="$JWT_SECRET" \
            --volume "$CONF_DIR/fastapi:/app/config:ro,Z" \
            --health-cmd="curl -f http://localhost:8000/healthz || exit 1" \
            --health-interval=30s \
            --health-timeout=10s \
            --health-retries=3 \
            docker.io/tiangolo/uvicorn-gunicorn-fastapi:python3.11 \
            /bin/sh -c "pip install asyncpg redis && uvicorn main:app --host 0.0.0.0 --port 8000"
    else
        info "FastAPI container already exists"
        if [ "$(podman container inspect "$FASTAPI_CONTAINER" --format '{{.State.Status}}')" != "running" ]; then
            log "Starting existing FastAPI container..."
            podman start "$FASTAPI_CONTAINER"
        fi
    fi
}

# Get initial SSL certificate
get_initial_cert() {
    if [ ! -f "$CERTS_DIR/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        log "Getting initial SSL certificate for $DOMAIN..."

        # Create temporary nginx for ACME challenge
        podman run -d \
            --name "${APP}_temp_nginx" \
            --pod "$POD_NAME" \
            --volume "$CERTS_DIR/letsencrypt:/var/www/certbot:ro,Z" \
            docker.io/nginx:alpine \
            /bin/sh -c "echo 'server { listen 80; location /.well-known/acme-challenge/ { root /var/www/certbot; } location / { return 404; } }' > /etc/nginx/conf.d/default.conf && nginx -g 'daemon off;'"

        sleep 5

        # Get certificate
        podman run --rm \
            --pod "$POD_NAME" \
            --volume "$CERTS_DIR/letsencrypt:/etc/letsencrypt:Z" \
            --volume "$CERTS_DIR/letsencrypt:/var/www/certbot:Z" \
            docker.io/certbot/certbot \
            certonly --webroot --webroot-path=/var/www/certbot \
            --email "$EMAIL" --agree-tos --no-eff-email \
            -d "$DOMAIN"

        # Stop temporary nginx
        podman stop "${APP}_temp_nginx" 2>/dev/null || true
        podman rm "${APP}_temp_nginx" 2>/dev/null || true

        if [ -f "$CERTS_DIR/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
            log "SSL certificate obtained successfully"
        else
            error "Failed to obtain SSL certificate"
            return 1
        fi
    else
        info "SSL certificate already exists"
    fi
}

# Start OpenResty container
start_openresty() {
    if ! podman container exists "$OPENRESTY_CONTAINER" 2>/dev/null; then
        log "Starting OpenResty container..."
        podman run -d \
            --name "$OPENRESTY_CONTAINER" \
            --pod "$POD_NAME" \
            --env JWT_SECRET="$JWT_SECRET" \
            --env REDIS_PASSWORD="$REDIS_PASSWORD" \
            --volume "$CONF_DIR/openresty/nginx.conf:/usr/local/openresty/nginx/conf/nginx.conf:ro,Z" \
            --volume "$CONF_DIR/openresty/lua:/usr/local/openresty/lua:ro,Z" \
            --volume "$CERTS_DIR/letsencrypt:/etc/letsencrypt:ro,Z" \
            --volume "$CERTS_DIR/letsencrypt:/var/www/certbot:Z" \
            --health-cmd="curl -f http://localhost:80 || exit 1" \
            --health-interval=30s \
            --health-timeout=10s \
            --health-retries=3 \
            docker.io/openresty/openresty:alpine \
            /bin/sh -c "luarocks install lua-resty-jwt && /usr/local/openresty/bin/openresty -g 'daemon off;'"
    else
        info "OpenResty container already exists"
        if [ "$(podman container inspect "$OPENRESTY_CONTAINER" --format '{{.State.Status}}')" != "running" ]; then
            log "Starting existing OpenResty container..."
            podman start "$OPENRESTY_CONTAINER"
        fi
    fi
}

# Start helper container
start_helper() {
    if ! podman container exists "$HELPER_CONTAINER" 2>/dev/null; then
        log "Starting helper container..."
        podman run -d \
            --name "$HELPER_CONTAINER" \
            --pod "$POD_NAME" \
            --env PGPASSWORD="$POSTGRES_PASSWORD" \
            docker.io/alpine:latest \
            /bin/sh -c "apk add --no-cache postgresql-client redis curl && sleep infinity"
    else
        info "Helper container already exists"
        if [ "$(podman container inspect "$HELPER_CONTAINER" --format '{{.State.Status}}')" != "running" ]; then
            log "Starting existing helper container..."
            podman start "$HELPER_CONTAINER"
        fi
    fi
}

# Start pgAdmin (optional)
start_pgadmin() {
    if [ "${ENABLE_PGADMIN:-false}" = "true" ]; then
        if ! podman container exists "$PGADMIN_CONTAINER" 2>/dev/null; then
            log "Starting pgAdmin container..."
            podman run -d \
                --name "$PGADMIN_CONTAINER" \
                --pod "$POD_NAME" \
                --env PGADMIN_DEFAULT_EMAIL="$EMAIL" \
                --env PGADMIN_DEFAULT_PASSWORD="$POSTGRES_PASSWORD" \
                docker.io/dpage/pgadmin4:latest
        else
            info "pgAdmin container already exists"
            if [ "$(podman container inspect "$PGADMIN_CONTAINER" --format '{{.State.Status}}')" != "running" ]; then
                log "Starting existing pgAdmin container..."
                podman start "$PGADMIN_CONTAINER"
            fi
        fi
    fi
}

# Wait for services to be healthy
wait_for_services() {
    log "Waiting for services to be healthy..."

    local services=("$POSTGRES_CONTAINER" "$REDIS_CONTAINER" "$FASTAPI_CONTAINER")
    local max_attempts=30
    local attempt=0

    for service in "${services[@]}"; do
        attempt=0
        while [ $attempt -lt $max_attempts ]; do
            if podman healthcheck run "$service" >/dev/null 2>&1; then
                log "$service is healthy"
                break
            else
                info "Waiting for $service to be healthy... ($((attempt + 1))/$max_attempts)"
                sleep 10
                ((attempt++))
            fi
        done

        if [ $attempt -eq $max_attempts ]; then
            error "$service failed to become healthy"
            return 1
        fi
    done

    log "All services are healthy"
}

# Generate systemd unit file
generate_systemd_unit() {
    local unit_file="$HOME/.config/systemd/user/${POD_NAME}.service"
    mkdir -p "$(dirname "$unit_file")"

    cat >"$unit_file" <<EOF
[Unit]
Description=Podman pod - $POD_NAME
Wants=network-online.target
After=network-online.target
RequiresMountsFor=%t/containers

[Service]
Environment=PODMAN_SYSTEMD_UNIT=%n
Restart=on-failure
TimeoutStopSec=70
ExecStart=/usr/bin/podman pod start $POD_NAME
ExecStop=/usr/bin/podman pod stop -t 60 $POD_NAME
Type=forking
PIDFile=%t/containers/overlays/containers.pid

[Install]
WantedBy=default.target
EOF

    log "Generated systemd unit file: $unit_file"
    info "To enable auto-start: systemctl --user enable ${POD_NAME}.service"
}

# Main functions
cmd_init() {
    log "Initializing $APP deployment..."

    # Generate default .env file with random secrets if it doesn't exist
    if [ ! -f "$ROOT_DIR/.env" ]; then
        log "Generating default .env file at $ROOT_DIR/.env"
        cat >"$ROOT_DIR/.env" <<EOF
APP=$APP
DOMAIN=$DOMAIN
EMAIL=$EMAIL
POSTGRES_DB=$POSTGRES_DB
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$(openssl rand -base64 24)
REDIS_PASSWORD=$(openssl rand -base64 24)
JWT_SECRET=$(openssl rand -hex 32)
EOF
        info "Default .env file created with random credentials"
    else
        info ".env file already exists, skipping generation"
    fi

    init_directories
    log "Initialization complete!"
    info "Next steps:"
    info "1. Review and update .env file"
    info "2. Run: ./fast.sh start"
}

cmd_start() {
    log "Starting $APP deployment..."

    create_network
    create_pod
    start_postgres
    start_redis

    # Wait a bit for databases to be ready
    sleep 10

    start_fastapi
    wait_for_services

    get_initial_cert
    start_openresty
    start_helper
    start_pgadmin

    generate_systemd_unit

    log "Deployment started successfully!"
    info "Services available at:"
    info "- Main app: https://$DOMAIN"
    info "- Health check: https://$DOMAIN/healthz"
    if [ "${ENABLE_PGLADMIN:-false}" = "true" ]; then
        info "- pgAdmin: http://$DOMAIN:8080"
    fi
}

cmd_stop() {
    log "Stopping $APP deployment..."

    if podman pod exists "$POD_NAME" 2>/dev/null; then
        podman pod stop "$POD_NAME"
        log "Pod stopped successfully"
    else
        warn "Pod $POD_NAME does not exist"
    fi
}

cmd_restart() {
    log "Restarting $APP deployment..."
    cmd_stop
    sleep 5
    cmd_start
}

cmd_status() {
    log "Checking $APP deployment status..."

    if podman pod exists "$POD_NAME" 2>/dev/null; then
        echo "Pod Status:"
        podman pod ps --filter name="$POD_NAME"
        echo
        echo "Container Status:"
        podman ps -a --filter pod="$POD_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo
        echo "Health Status:"
        local containers=("$POSTGRES_CONTAINER" "$REDIS_CONTAINER" "$FASTAPI_CONTAINER" "$OPENRESTY_CONTAINER")
        for container in "${containers[@]}"; do
            if podman container exists "$container" 2>/dev/null; then
                local health
                health=$(podman inspect "$container" --format '{{.State.Health.Status}}' \
                    2>/dev/null || echo "no healthcheck")
                echo "$container: $health"
            fi
        done
    else
        warn "Pod $POD_NAME does not exist"
    fi
}

cmd_logs() {
    local container="${2:-}"
    if [ -n "$container" ]; then
        podman logs -f "${APP}_${container}"
    else
        log "Available containers:"
        podman ps --filter pod="$POD_NAME" --format "{{.Names}}" | sed 's/^/  - /'
        echo
        info "Usage: $0 logs <container_name>"
        info "Example: $0 logs fastapi"
    fi
}

cmd_clean() {
    warn "This will remove all containers and data. Are you sure? (y/N)"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        log "Cleaning up $APP deployment..."

        # Stop and remove pod
        if podman pod exists "$POD_NAME" 2>/dev/null; then
            podman pod rm -f "$POD_NAME"
        fi

        # Remove network
        if podman network exists "$NETWORK_NAME" 2>/dev/null; then
            podman network rm "$NETWORK_NAME"
        fi

        # Remove systemd unit
        local unit_file="$HOME/.config/systemd/user/${POD_NAME}.service"
        if [ -f "$unit_file" ]; then
            systemctl --user disable "${POD_NAME}.service" 2>/dev/null || true
            rm -f "$unit_file"
        fi

        log "Cleanup complete"
        warn "Data directories preserved. Remove manually if needed:"
        warn "  rm -rf $DATA_DIR"
    else
        info "Cleanup cancelled"
    fi
}

# Main script logic
case "${1:-}" in
init)
    cmd_init
    ;;
start)
    cmd_start
    ;;
stop)
    cmd_stop
    ;;
restart)
    cmd_restart
    ;;
status)
    cmd_status
    ;;
logs)
    cmd_logs "$@"
    ;;
clean)
    cmd_clean
    ;;
*)
    echo "Usage: $0 {init|start|stop|restart|status|logs|clean}"
    echo ""
    echo "Commands:"
    echo "  init     - Initialize directory structure and config files"
    echo "  start    - Start all services"
    echo "  stop     - Stop all services"
    echo "  restart  - Restart all services"
    echo "  status   - Show service status"
    echo "  logs     - Show logs for a specific container"
    echo "  clean    - Remove all containers and networks"
    exit 1
    ;;
esac
