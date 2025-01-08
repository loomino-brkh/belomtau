#!/bin/bash

# Handle case when APP_NAME is not set yet
if [ -z "$APP_NAME" ]; then
    APP_NAME="default"
fi

# ---- Host Configuration -------
HOST_DOMAIN="api.var.my.id"
PORT1="8080"  # Nginx port
PORT2="8000"  # FastAPI port
PORT3="8001"  # Django port

# ---- Directory Configuration -------
PROJECT_DIR="$HOME/fast_projects/api_${APP_NAME}"
SUPPORT_DIR="${PROJECT_DIR}/support"
MAIN_DIR="${PROJECT_DIR}/main"
DJANGO_DIR="${PROJECT_DIR}/django_auth"
ROOT_DIR="$HOME/.root_dir"

# ---- Container Images -------
POSTGRES_IMAGE="docker.io/library/postgres:16"
PYTHON_IMAGE="docker.io/library/python:latest"
REDIS_IMAGE="docker.io/library/redis:latest"
NGINX_IMAGE="docker.io/library/nginx:latest"
PGADMIN_IMAGE="docker.io/dpage/pgadmin4:latest"

# ---- Container Names -------
POD_NAME="${APP_NAME}_pod"

# ---- Database Configuration -------
POSTGRES_DB="${APP_NAME}_db"
POSTGRES_USER="${APP_NAME}_user"
POSTGRES_PASSWORD="supersecure"

# ---- Container Names -------
POSTGRES_CONTAINER_NAME="${APP_NAME}_postgres"
REDIS_CONTAINER_NAME="${APP_NAME}_redis"
UVICORN_CONTAINER_NAME="${APP_NAME}_uvicorn"
DJANGO_CONTAINER_NAME="${APP_NAME}_django"
NGINX_CONTAINER_NAME="${APP_NAME}_nginx"
PGADMIN_CONTAINER_NAME="${APP_NAME}_pgadmin"
CFL_TUNNEL_CONTAINER_NAME="${APP_NAME}_cfltunnel"
INTERACT_CONTAINER_NAME="${APP_NAME}_interact"

# ---- File Paths -------
REQUIREMENTS_FILE="${SUPPORT_DIR}/requirements.txt"
MAIN_FILE="${MAIN_DIR}/main.py"
DB_FILE="${MAIN_DIR}/db.py"
SCHEMAS_FILE="${MAIN_DIR}/schemas.py"

# ---- Generate Random Key -------
RANDOM_KEY=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)

# ---- Common Functions -------
check_podman() {
  if ! command -v podman &> /dev/null; then
    echo "Error: podman is not installed"
    exit 1
  fi
}

check_required_args() {
  if [ -z "$APP_NAME" ] || [ -z "$COMMAND" ]; then
    echo "Error: App name and command are required"
    echo "Usage: $0 <app_name> <command>"
    exit 1
  fi
}