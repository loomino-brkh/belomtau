#!/bin/bash
# ---- Configuration -------
HOST_DOMAIN="educto.brkh.work"
PORT="8080"

APP_NAME="$2"
PROJECT_DIR="$HOME/projects/vue_${APP_NAME}"

NODE_IMAGE="docker.io/library/node:latest"
NGINX_IMAGE="docker.io/library/nginx:latest"

POD_NAME="${APP_NAME}_pod"
NODE_CONTAINER_NAME="${APP_NAME}_node"
NGINX_CONTAINER_NAME="${APP_NAME}_nginx"
CFL_TUNNEL_CONTAINER_NAME="${APP_NAME}_cfltunnel"

init() {
    [ ! -d "$PROJECT_DIR" ] && mkdir -p "$PROJECT_DIR"
    [ ! -f "$PROJECT_DIR/token" ] && touch "$PROJECT_DIR/token"
    
    # Create package.json
    # Create package.json if it doesn't exist
    if [ ! -f "$PROJECT_DIR/package.json" ]; then
        cat >"$PROJECT_DIR/package.json" <<EOL
{
  "name": "${APP_NAME}",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "serve": "vite preview"
  },
  "dependencies": {
    "vue": "^3.3.4",
    "vue-router": "^4.2.4",
    "pinia": "^2.1.6",
    "axios": "^1.4.0"
  },
  "devDependencies": {
    "@vitejs/plugin-vue": "^4.3.4",
    "vite": "^4.4.9"
  }
}
EOL
    fi

    # Create vite.config.js if it doesn't exist
    if [ ! -f "$PROJECT_DIR/vite.config.js" ]; then
        cat >"$PROJECT_DIR/vite.config.js" <<EOL
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue()],
  server: {
    host: '0.0.0.0',
    port: 8090
  }
})
EOL
    fi

    # Create nginx.conf if it doesn't exist
    if [ ! -f "$PROJECT_DIR/nginx.conf" ]; then
        cat >"$PROJECT_DIR/nginx.conf" <<EOL
server {
    listen $PORT;
    server_name localhost;

    location / {
        proxy_pass http://localhost:8090;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOL
    fi
}

stop() {
    podman pod stop "$POD_NAME"
    podman pod rm "$POD_NAME"
}

run_node() {
    podman run -d --pod "$POD_NAME" --name "$NODE_CONTAINER_NAME" \
        -v "$PROJECT_DIR:/app:z" \
        -w /app \
        "$NODE_IMAGE" sh -c "npm install && npm run dev"
}

run_nginx() {
    podman run -d --pod "$POD_NAME" --name "$NGINX_CONTAINER_NAME" \
        -v "$PROJECT_DIR/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
        "$NGINX_IMAGE"
}

run_cfl_tunnel() {
    podman run -d --pod "$POD_NAME" --name "$CFL_TUNNEL_CONTAINER_NAME" \
        docker.io/cloudflare/cloudflared:latest tunnel --no-autoupdate run \
        --token $(cat "$PROJECT_DIR/token")
}

pod_create() {
    podman pod create --name "$POD_NAME" --network bridge
}

start() {
    pod_create
    run_node
    run_nginx
    run_cfl_tunnel
}

cek() {
    if podman pod exists "$POD_NAME"; then
        if [ "$(podman pod ps --filter name="$POD_NAME" --format "{{.Status}}" | awk '{print $1}')" = "Running" ]; then
            for container in "${NODE_CONTAINER_NAME}" "${NGINX_CONTAINER_NAME}" "${CFL_TUNNEL_CONTAINER_NAME}"; do
                if [ "$(podman ps --filter name="$container" --format "{{.Status}}" | awk '{print $1}')" != "Up" ]; then
                    echo "Container $container is not running. Restarting..."
                    podman start "$container"
                    return
                fi
            done
            echo "All containers are running."
        else
            podman pod start "$POD_NAME"
        fi
    else
        echo "Pod is not running. Starting..."
        start
    fi
}

$1
