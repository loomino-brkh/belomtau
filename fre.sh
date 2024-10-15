#!/bin/bash
# ---- Configuration -------
HOST_DOMAIN="dev.var.my.id"
PORT="9000"

APP_NAME="$2"
PROJECT_DIR="$HOME/eskrim/fre_${APP_NAME}"

PYTHON_IMAGE="docker.io/library/python:latest"
NGINX_IMAGE="docker.io/library/nginx:latest"

POD_NAME="${APP_NAME}_fre_pod"

GUNICORN_CONTAINER_NAME="${APP_NAME}_fre_gunicorn"
FRONTEND_CONTAINER_NAME="${APP_NAME}_fre_frontend"
CFL_TUNNEL_CONTAINER_NAME="${APP_NAME}_fre_cfltunnel"
INTERACT_CONTAINER_NAME="${APP_NAME}_fre_interact"

REQUIREMENTS_FILE="${PROJECT_DIR}/requirements.txt"
SETTINGS_FILE="${PROJECT_DIR}/${APP_NAME}/${APP_NAME}/settings.py"

init() {
    [ ! -d "$PROJECT_DIR" ] && mkdir -p "$PROJECT_DIR"
    [ ! -d "$PROJECT_DIR/.root" ] && mkdir -p "$PROJECT_DIR/.root"
    [ ! -f "$PROJECT_DIR/token" ] && touch "$PROJECT_DIR/token"
    [ ! -d "$PROJECT_DIR/frontend" ] && mkdir -p "$PROJECT_DIR/frontend"

    cat >"$REQUIREMENTS_FILE" <<EOL
Django
gunicorn
EOL

    podman run --rm -v "$PROJECT_DIR:/app" "$PYTHON_IMAGE" python -m venv /app/venv
    podman run --rm -v "$PROJECT_DIR:/app" -w /app "$PYTHON_IMAGE" bash -c "source /app/venv/bin/activate && pip install --upgrade pip && pip install -r /app/requirements.txt"
    podman run --rm -v "$PROJECT_DIR:/app" -w /app "$PYTHON_IMAGE" bash -c "/app/venv/bin/django-admin startproject $APP_NAME"

    [ ! -d "$PROJECT_DIR/${APP_NAME}/staticfiles" ] && mkdir -p "$PROJECT_DIR/${APP_NAME}/staticfiles"
    [ ! -d "$PROJECT_DIR/${APP_NAME}/staticfiles/css" ] && mkdir -p "$PROJECT_DIR/${APP_NAME}/staticfiles/css"
    [ ! -d "$PROJECT_DIR/${APP_NAME}/staticfiles/js" ] && mkdir -p "$PROJECT_DIR/${APP_NAME}/staticfiles/js"

    if [ ! -f "$PROJECT_DIR/gunicorn.sh" ] || ! cmp -s <(cat <<EOL
#!/bin/bash
source /app/venv/bin/activate
cd /app/${APP_NAME}
exec gunicorn --reload --log-level=debug --workers 5 --bind 0.0.0.0:8900 $APP_NAME.wsgi:application
EOL
) "$PROJECT_DIR/gunicorn.sh"; then
    cat >"$PROJECT_DIR/gunicorn.sh" <<EOL
#!/bin/bash
source /app/venv/bin/activate
cd /app/${APP_NAME}
exec gunicorn --reload --log-level=debug --workers 5 --bind 0.0.0.0:8900 $APP_NAME.wsgi:application
EOL
    fi

    chmod +x "$PROJECT_DIR/gunicorn.sh"

    if [ ! -f "$PROJECT_DIR/frontend.conf" ] || ! cmp -s <(cat <<EOL
server {
    listen $PORT;
    server_name 127.0.0.1;

    location / {
        root /www/frontend;
        index index.html;
    }

    location /css/ {
        alias /www/staticfiles/css/;
    }

    location /js/ {
        alias /www/staticfiles/js/;
    }
}
EOL
) "$PROJECT_DIR/frontend.conf"; then
    cat >"$PROJECT_DIR/frontend.conf" <<EOL
server {
    listen $PORT;
    server_name 127.0.0.1;

    location / {
        root /www/frontend;
        index index.html;
    }

    location /css/ {
        alias /www/staticfiles/css/;
    }

    location /js/ {
        alias /www/staticfiles/js/;
    }
}
EOL
    fi
}

stop() {
    podman pod stop "$POD_NAME"
    podman pod rm "$POD_NAME"
}


run_frontend() {
    podman run -d --pod "$POD_NAME" --name "$FRONTEND_CONTAINER_NAME" \
        -v "$PROJECT_DIR/frontend.conf:/etc/nginx/conf.d/default.conf:ro" \
        -v "$PROJECT_DIR/frontend:/www/frontend:ro" \
        -v "$PROJECT_DIR/${APP_NAME}/staticfiles:/www/staticfiles:ro" \
        "$NGINX_IMAGE"
}

run_cfl_tunnel() {
    podman run -d --pod "$POD_NAME" --name "$CFL_TUNNEL_CONTAINER_NAME" \
        docker.io/cloudflare/cloudflared:latest tunnel --no-autoupdate run \
        --token $(cat "$PROJECT_DIR/token")
}


run_gunicorn() {
    podman run -d --pod "$POD_NAME" --name "$GUNICORN_CONTAINER_NAME" \
        -v "$PROJECT_DIR:/app:ro" -w /app \
        "$PYTHON_IMAGE" bash -c "./gunicorn.sh"
}

run_interact() {
    podman run -d --pod "$POD_NAME" --name "$INTERACT_CONTAINER_NAME" \
        -v "$PROJECT_DIR/.root:/root:z" -w /root \
        -v "$PROJECT_DIR/:/app:z" -w /app \
        "$PYTHON_IMAGE" bash -c "sleep infinity"
}

pod_create() {
    podman pod create --name "$POD_NAME" --network bridge
}

esse() {
    run_gunicorn
    run_frontend
    run_cfl_tunnel
    run_interact
}


start() {
    pod_create
    esse
}

cek() {
    if podman pod exists "$POD_NAME"; then
        if [ "$(podman pod ps --filter name="$POD_NAME" --format "{{.Status}}" | awk '{print $1}')" = "Running" ]; then
            for container in "${GUNICORN_CONTAINER_NAME}" "${CFL_TUNNEL_CONTAINER_NAME}" "${FRONTEND_CONTAINER_NAME}" "${INTERACT_CONTAINER_NAME}"; do
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
