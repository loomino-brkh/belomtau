#!/bin/bash
# ---- Configuration -------
HOST_IP="192.168.212.77"
HOST_DOMAIN="dev.var.my.id"
PORT="8080"

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

init() {
    [ ! -d "$PROJECT_DIR" ] && mkdir -p "$PROJECT_DIR"
    [ ! -d "$PROJECT_DIR/db_data" ] && mkdir -p "$PROJECT_DIR/db_data"
    [ ! -d "$PROJECT_DIR/redis_data" ] && mkdir -p "$PROJECT_DIR/redis_data"
    [ ! -d "$PROJECT_DIR/.root" ] && mkdir -p "$PROJECT_DIR/.root"
    [ ! -f "$PROJECT_DIR/token" ] && touch "$PROJECT_DIR/token"
    [ ! -d "$PROJECT_DIR/pgadmin" ] && mkdir -p "$PROJECT_DIR/pgadmin" && chmod 777 "$PROJECT_DIR/pgadmin"

    cat >"$REQUIREMENTS_FILE" <<EOL
Django>=4.0
djangorestframework
djangorestframework-simplejwt
django-ratelimit
django-cors-headers
psycopg2-binary
gunicorn
django-redis
EOL

    podman run --rm -v "$PROJECT_DIR:/app" "$PYTHON_IMAGE" python -m venv /app/venv
    podman run --rm -v "$PROJECT_DIR:/app" -w /app "$PYTHON_IMAGE" bash -c "source /app/venv/bin/activate && pip install --upgrade pip && pip install -r /app/requirements.txt"
    podman run --rm -v "$PROJECT_DIR:/app" -w /app "$PYTHON_IMAGE" bash -c "/app/venv/bin/django-admin startproject $APP_NAME"

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
exec gunicorn --reload --log-level=debug --workers 10 --bind 0.0.0.0:8000 $APP_NAME.wsgi:application
EOL

    chmod +x "$PROJECT_DIR/gunicorn.sh"

    cat >"$PROJECT_DIR/nginx.conf" <<EOL
server {
    listen $PORT;
    server_name $HOST_IP;

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
EOL
}

stop() {
    podman pod stop "$POD_NAME"
    #podman pod rm "$POD_NAME"
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
        "$REDIS_IMAGE"
}

run_nginx() {
    podman run -d --pod "$POD_NAME" --name "$NGINX_CONTAINER_NAME" \
        -v "$PROJECT_DIR/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
        -v "$PROJECT_DIR/${APP_NAME}/staticfiles:/www/staticfiles:ro" \
        -v "$PROJECT_DIR/cert:/cert:ro" \
        "$NGINX_IMAGE"
}

run_cfl_tunnel() {
    if [ -f "$PROJECT_DIR/token" ]; then
        podman run -d --pod "$POD_NAME" --name "$CFL_TUNNEL_CONTAINER_NAME" \
            docker.io/cloudflare/cloudflared:latest tunnel --no-autoupdate run \
            --token $(cat "$PROJECT_DIR/token")
    else
        echo "Cloudflare Tunnel token file is missing."
    fi
}


run_gunicorn() {
    podman run -d --pod "$POD_NAME" --name "$GUNICORN_CONTAINER_NAME" \
        -v "$PROJECT_DIR:/app:ro" -w /app \
        "$PYTHON_IMAGE" bash -c "./gunicorn.sh"
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
    podman pod create --name "$POD_NAME" --publish ${HOST_IP}:${PORT}:${PORT} --publish ${HOST_IP}:5050:5050 --network bridge
}

esse() {

    run_postgres
    run_redis
    echo "Waiting for the database to be ready"
    sleep 5

    podman run --rm --pod "$POD_NAME" --name "$APP_NAME"_migrate \
        -v "$PROJECT_DIR:/app:ro" \
        -w /app/"$APP_NAME" \
        "$PYTHON_IMAGE" bash -c "source /app/venv/bin/activate && python manage.py migrate"

    run_gunicorn
    run_nginx
    run_cfl_tunnel
}


start() {
    
    if podman pod exists "$POD_NAME"; then
        podman pod start "$POD_NAME"
    fi

    if [ ! -d "$PROJECT_DIR" ]; then
        read -p "The project directory does not exist. Do you want to initialize it? (y/n): " confirm
        if [ "$confirm" = "y" ]; then
            init
        else
            echo "Initialization aborted."
            exit 1
        fi
    fi

    [ ! -d "$PROJECT_DIR/${APP_NAME}/static" ] && mkdir -p "$PROJECT_DIR/${APP_NAME}/static"
    pod_create
    esse

    echo "Django application setup complete. Access the app at http://${HOST_IP}:${PORT} or https://${HOST_DOMAIN}/"
}

cek() {
    if podman pod exists "$POD_NAME"; then
        if [ "$(podman pod ps --filter name="$POD_NAME" --format "{{.Status}}" | awk '{print $1}')" = "Running" ]; then
            for container in "${POSTGRES_CONTAINER_NAME}" "${REDIS_CONTAINER_NAME}" "${GUNICORN_CONTAINER_NAME}" "${NGINX_CONTAINER_NAME}" "${CFL_TUNNEL_CONTAINER_NAME}"; do
                if [ "$(podman ps --filter name="$container" --format "{{.Status}}" | awk '{print $1}')" != "Up" ]; then
                    echo "Container $container is not running. Restarting..."
                    podman start "$container"
                    return
                fi
            done
            echo "All containers are running."
        else
            echo "Pod is not running. Restarting..."
            esse
        fi
    else
        echo "Pod does not exist. Restarting..."
        pod_create
        esse
    fi
}


$1
