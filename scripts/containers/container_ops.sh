#!/bin/bash

# Get base directory (parent of scripts)
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$BASE_DIR/scripts"

# Source config with absolute path
source "$SCRIPT_DIR/config/config.sh"

# ---- Pod Management -------
pod_create() {
  echo "Creating pod..."
  podman pod create --name "$POD_NAME" --network bridge
}

pod_stop() {
  echo "Stopping and removing pod..."
  podman pod stop "$POD_NAME" || true
  podman pod rm "$POD_NAME" || true
}

# ---- Container Management -------
run_container() {
  local name=$1
  local image=$2
  local command=$3
  shift 3
  local args=("$@")

  echo "Starting $name container..."
  podman run -d --pod "$POD_NAME" --name "$name" "${args[@]}" "$image" $command
}

wait_for_service() {
  local name=$1
  local check_command=$2
  local max_attempts=$3
  local sleep_time=$4
  
  echo "Waiting for $name to be ready..."
  for i in $(seq 1 $max_attempts); do
    if podman exec -it "$name" $check_command &>/dev/null; then
      echo "$name is ready."
      return 0
    fi
    sleep $sleep_time
  done
  echo "$name did not become ready in time."
  return 1
}

# ---- Service-Specific Containers -------
run_postgres() {
  run_container "$POSTGRES_CONTAINER_NAME" "$POSTGRES_IMAGE" "" \
    -e "POSTGRES_DB=$POSTGRES_DB" \
    -e "POSTGRES_USER=$POSTGRES_USER" \
    -e "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" \
    -v "$SUPPORT_DIR/db_data:/var/lib/postgresql/data:z"
}

run_redis() {
  run_container "$REDIS_CONTAINER_NAME" "$REDIS_IMAGE" "--loglevel warning" \
    -v "$SUPPORT_DIR/redis_data:/data:z"
}

run_nginx() {
  run_container "$NGINX_CONTAINER_NAME" "$NGINX_IMAGE" "" \
    -v "$SUPPORT_DIR/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
    -v "$DJANGO_DIR/static:/www/django_auth/staticfiles:ro"
}

run_uvicorn() {
  run_container "$UVICORN_CONTAINER_NAME" "$PYTHON_IMAGE" "./support/uvicorn.sh" \
    -v "$PROJECT_DIR:/app:z" \
    -e "POSTGRES_CONTAINER_NAME=$POSTGRES_CONTAINER_NAME" \
    -e "REDIS_CONTAINER_NAME=$REDIS_CONTAINER_NAME" \
    -e "DJANGO_CONTAINER_NAME=$DJANGO_CONTAINER_NAME" \
    -e "POSTGRES_USER=$POSTGRES_USER" \
    -e "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" \
    -e "POSTGRES_DB=$POSTGRES_DB" \
    -e "DJANGO_SECRET_KEY=$RANDOM_KEY" \
    -w /app
}

run_django() {
  run_container "$DJANGO_CONTAINER_NAME" "$PYTHON_IMAGE" "./django_auth/run.sh" \
    -v "$PROJECT_DIR:/app:z" \
    -e "POSTGRES_CONTAINER_NAME=$POSTGRES_CONTAINER_NAME" \
    -e "POSTGRES_USER=$POSTGRES_USER" \
    -e "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" \
    -e "POSTGRES_DB=$POSTGRES_DB" \
    -w /app
}

run_interact() {
  run_container "$INTERACT_CONTAINER_NAME" "$PYTHON_IMAGE" "sleep infinity" \
    -v "$ROOT_DIR:/root:z" \
    -v "$PROJECT_DIR:/app:z" \
    -w /app
}

run_pgadmin() {
  run_container "$PGADMIN_CONTAINER_NAME" "$PGADMIN_IMAGE" "" \
    -e "PGADMIN_DEFAULT_EMAIL=dyka@brkh.work" \
    -e "PGADMIN_DEFAULT_PASSWORD=SuperSecret" \
    -e "PGADMIN_LISTEN_PORT=5050" \
    -v "$SUPPORT_DIR/pgadmin:/var/lib/pgadmin:z"
}

run_cfl_tunnel() {
  if [ ! -s "$SUPPORT_DIR/token" ]; then
    echo "Error: Cloudflare tunnel token is empty. Please add your token to $SUPPORT_DIR/token"
    return 1
  fi

  run_container "$CFL_TUNNEL_CONTAINER_NAME" "docker.io/cloudflare/cloudflared:latest" \
    "tunnel --no-autoupdate run --token $(cat "$SUPPORT_DIR/token")"
}

# ---- Service Health Checks -------
wait_for_postgres() {
  wait_for_service "$POSTGRES_CONTAINER_NAME" "pg_isready -U $POSTGRES_USER" 30 2
}

wait_for_django() {
  wait_for_service "$DJANGO_CONTAINER_NAME" "curl -s http://127.0.0.1:8001/auth/login/" 60 2
}

# ---- Container Status Check -------
check_container_status() {
  local container=$1
  if [ "$(podman ps --filter name="$container" --format "{{.Status}}" | awk '{print $1}')" != "Up" ]; then
    echo "Container $container is not running. Restarting..."
    podman start "$container" || return 1
  fi
}

check_all_containers() {
  local containers=(
    "$POSTGRES_CONTAINER_NAME"
    "$REDIS_CONTAINER_NAME"
    "$DJANGO_CONTAINER_NAME"
    "$UVICORN_CONTAINER_NAME"
    "$NGINX_CONTAINER_NAME"
    "$CFL_TUNNEL_CONTAINER_NAME"
    "$INTERACT_CONTAINER_NAME"
  )

  for container in "${containers[@]}"; do
    check_container_status "$container" || return 1
  done
  echo "All containers are running."
}