#!/bin/bash
# ---- Configuration -------
HOST_DOMAIN="dev.var.my.id"
PORT1="8080"
PORT2="9080"

APP_NAME="$2"
PROJECT_DIR="$HOME/eskrim/api_${APP_NAME}"

POSTGRES_IMAGE="docker.io/library/postgres:16"
PYTHON_IMAGE="docker.io/library/python:latest"
REDIS_IMAGE="docker.io/library/redis:latest"
NGINX_IMAGE="docker.io/library/nginx:latest"
PGADMIN_IMAGE="docker.io/dpage/pgadmin4:latest"

POD_NAME="${APP_NAME}_pod"

POSTGRES_DB="${APP_NAME}_db"
POSTGRES_USER="${APP_NAME}_user"
POSTGRES_PASSWORD="supersecure"

POSTGRES_CONTAINER_NAME="${APP_NAME}_postgres"
REDIS_CONTAINER_NAME="${APP_NAME}_redis"
GUNICORN_CONTAINER_NAME="${APP_NAME}_gunicorn"
NGINX_CONTAINER_NAME="${APP_NAME}_nginx"
PGADMIN_CONTAINER_NAME="${APP_NAME}_pgadmin"
CFL_TUNNEL_CONTAINER_NAME="${APP_NAME}_cfltunnel"
INTERACT_CONTAINER_NAME="${APP_NAME}_interact"

REQUIREMENTS_FILE="${PROJECT_DIR}/requirements.txt"
SETTINGS_FILE="${PROJECT_DIR}/${APP_NAME}/${APP_NAME}/settings.py"

rev() {
    podman run --rm -v "$PROJECT_DIR:/app" "$PYTHON_IMAGE" python -m venv /app/venv
    podman run --rm -v "$PROJECT_DIR:/app" -w /app "$PYTHON_IMAGE" bash -c "source /app/venv/bin/activate && pip install --upgrade pip && pip install -r /app/requirements.txt"
}

init() {
    [ ! -d "$PROJECT_DIR" ] && mkdir -p "$PROJECT_DIR"
    [ ! -d "$PROJECT_DIR/db_data" ] && mkdir -p "$PROJECT_DIR/db_data"
    [ ! -d "$PROJECT_DIR/redis_data" ] && mkdir -p "$PROJECT_DIR/redis_data"
    [ ! -d "$PROJECT_DIR/.root" ] && mkdir -p "$PROJECT_DIR/.root"
    [ ! -f "$PROJECT_DIR/token" ] && touch "$PROJECT_DIR/token"
    [ ! -d "$PROJECT_DIR/pgadmin" ] && mkdir -p "$PROJECT_DIR/pgadmin" && chmod 777 "$PROJECT_DIR/pgadmin"
    [ ! -d "$PROJECT_DIR/frontend" ] && mkdir -p "$PROJECT_DIR/frontend"
    [ ! -d "$PROJECT_DIR/staticfiles" ] && mkdir -p "$PROJECT_DIR/staticfiles"
    [ ! -d "$PROJECT_DIR/mediafiles" ] && mkdir -p "$PROJECT_DIR/mediafiles"


    cat >"$REQUIREMENTS_FILE" <<EOL
Django
djangorestframework
djangorestframework-simplejwt
django-ratelimit
django-cors-headers
psycopg2-binary
gunicorn
django-redis
Pillow
EOL

    rev
    podman run --rm -v "$PROJECT_DIR:/app" -w /app "$PYTHON_IMAGE" bash -c "/app/venv/bin/django-admin startproject $APP_NAME"
    [ ! -d "$PROJECT_DIR/${APP_NAME}/static" ] && mkdir -p "$PROJECT_DIR/${APP_NAME}/static"
    [ ! -d "$PROJECT_DIR/staticfiles" ] && mkdir -p "$PROJECT_DIR/staticfiles"

    sed -i "s/ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = \[/g" "${SETTINGS_FILE}"
    sed -i "/ALLOWED_HOSTS = \[/a\     '$HOST_IP',\n     '$HOST_DOMAIN',\n\]" "${SETTINGS_FILE}"
    sed -i "s/'ENGINE': 'django.db.backends.sqlite3'/'ENGINE': 'django.db.backends.postgresql'/g" "${SETTINGS_FILE}"
    sed -i "s/'NAME': BASE_DIR \/ 'db.sqlite3'/'NAME': '$POSTGRES_DB'/g" "${SETTINGS_FILE}"
    sed -i "/'NAME': '$POSTGRES_DB'/a\        'USER': '$POSTGRES_USER',\n        'PASSWORD': '$POSTGRES_PASSWORD',\n        'HOST': 'localhost',\n        'PORT': '5432'," "${SETTINGS_FILE}"

    cat <<EOL >>"${SETTINGS_FILE}"
CACHES = {
    'default': {
        'BACKEND': 'django_redis.cache.RedisCache',
        'LOCATION': 'redis://localhost:6379/1',
        'OPTIONS': {
            'CLIENT_CLASS': 'django_redis.client.DefaultClient',
        }
    }
}
EOL

    cat >"$PROJECT_DIR/gunicorn.sh" <<EOL
#!/bin/bash
source /app/venv/bin/activate
cd /app/${APP_NAME}
exec gunicorn --reload --log-level=debug --workers 2 --bind 0.0.0.0:8000 $APP_NAME.wsgi:application
EOL

    chmod +x "$PROJECT_DIR/gunicorn.sh"

    cat >"$PROJECT_DIR/nginx.conf" <<EOL
server {
    listen $PORT1;
    server_name 127.0.0.1;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /static/ {
        alias /www/staticfiles/;
    }
    
    location /api/ {
        proxy_pass http://127.0.0.1:8000/api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

server {
    listen $PORT2;
    server_name 127.0.0.1;

    location / {
        alias /www/frontend/;
    }
}
EOL
}

stop() {
    podman pod stop "$POD_NAME"
    podman pod rm "$POD_NAME"
}

run_postgres() {
    podman run -d --pod "$POD_NAME" --name "$POSTGRES_CONTAINER_NAME" \
        -e POSTGRES_DB="$POSTGRES_DB" \
        -e POSTGRES_USER="$POSTGRES_USER" \
        -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
        -v "$PROJECT_DIR/db_data:/var/lib/postgresql/data:z" \
        "$POSTGRES_IMAGE"
}

run_redis() {
    podman run -d --pod "$POD_NAME" --name "$REDIS_CONTAINER_NAME" \
        -v "$PROJECT_DIR/redis_data:/data:z" \
        "$REDIS_IMAGE" --loglevel verbose
}

run_nginx() {
    podman run -d --pod "$POD_NAME" --name "$NGINX_CONTAINER_NAME" \
        -v "$PROJECT_DIR/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
        -v "$PROJECT_DIR/${APP_NAME}/staticfiles:/www/staticfiles:ro" \
        -v "$PROJECT_DIR/frontend:/www/frontend:ro" \
        -v "$PROJECT_DIR/media:/www/media:ro" \
        "$NGINX_IMAGE"
}

run_cfl_tunnel() {
    podman run -d --pod "$POD_NAME" --name "$CFL_TUNNEL_CONTAINER_NAME" \
        docker.io/cloudflare/cloudflared:latest tunnel --no-autoupdate run \
        --token $(cat "$PROJECT_DIR/token")
}


run_gunicorn() {
    podman run -d --pod "$POD_NAME" --name "$GUNICORN_CONTAINER_NAME" \
        -v "$PROJECT_DIR:/app:ro" \
        -v "$PROJECT_DIR/media:/app/media:z" \
        -w /app \
        "$PYTHON_IMAGE" bash -c "./gunicorn.sh"
}

run_interact() {
    podman run -d --pod "$POD_NAME" --name "$INTERACT_CONTAINER_NAME" \
        -v "$PROJECT_DIR/.root:/root:z" -w /root \
        -v "$PROJECT_DIR/:/app:z" -w /app \
        "$PYTHON_IMAGE" bash -c "sleep infinity"
}

pg() {
    podman run -d --rm --pod "$POD_NAME" --name "$PGADMIN_CONTAINER_NAME" \
        -e "PGADMIN_DEFAULT_EMAIL=dyka@brkh.work" \
        -e "PGADMIN_DEFAULT_PASSWORD=SuperSecret" \
        -e "PGADMIN_LISTEN_PORT=5050" \
        -v "$PROJECT_DIR/pgadmin:/var/lib/pgadmin:z" \
        "$PGADMIN_IMAGE"
}

pod_create() {
    podman pod create --name "$POD_NAME" --network bridge
}

esse() {
    run_postgres
    run_redis
    run_gunicorn
    run_nginx
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
            for container in "${POSTGRES_CONTAINER_NAME}" "${REDIS_CONTAINER_NAME}" "${GUNICORN_CONTAINER_NAME}" "${NGINX_CONTAINER_NAME}" "${CFL_TUNNEL_CONTAINER_NAME}" "${INTERACT_CONTAINER_NAME}"; do
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
