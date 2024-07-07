#!/bin/bash

# ---- Configuration -------
APP_NAME="$2"
PROJECT_DIR="$HOME/django_${APP_NAME}"
#VENV_DIR="${PROJECT_DIR}/venv"

HOST_IP="192.168.22.10"
PORT="8080"

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

#SETTINGS_FILE_MODULE="${APP_NAME}.settings"
REQUIREMENTS_FILE="${PROJECT_DIR}/requirements.txt"
SETTINGS_FILE="${PROJECT_DIR}/${APP_NAME}/${APP_NAME}/settings.py"

# ---- Configuration -------

init() {

# Create project directory 
mkdir -p "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/db_data"
mkdir -p "$PROJECT_DIR/redis_data"
mkdir -p "$PROJECT_DIR/pgadmin"

chmod 777 "$PROJECT_DIR/pgadmin"

# Create requirements.txt 
cat > "$REQUIREMENTS_FILE" <<EOL
Django>=4.0
psycopg2-binary
gunicorn
django-redis
EOL

# Create virtualenv 
podman run --rm -v "$PROJECT_DIR:/app" "$PYTHON_IMAGE" python -m venv /app/venv

# Activate virtualenv and install requirements
podman run --rm -v "$PROJECT_DIR:/app" -w /app "$PYTHON_IMAGE" bash -c "source /app/venv/bin/activate && pip install -r /app/requirements.txt"

# Create Django project 
podman run --rm -v "$PROJECT_DIR:/app" -w /app "$PYTHON_IMAGE" bash -c "/app/venv/bin/django-admin startproject $APP_NAME"

sed -i "s/ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = \[/g" "${SETTINGS_FILE}"
sed -i "/ALLOWED_HOSTS = \[/a\     '$HOST_IP',\n     'dev.var.my.id',\n\]" "${SETTINGS_FILE}"

sed -i "s/'ENGINE': 'django.db.backends.sqlite3'/'ENGINE': 'django.db.backends.postgresql'/g" "${SETTINGS_FILE}"
sed -i "s/'NAME': BASE_DIR \/ 'db.sqlite3'/'NAME': '$POSTGRES_DB'/g" "${SETTINGS_FILE}"
sed -i "/'NAME': '$POSTGRES_DB'/a\        'USER': '$POSTGRES_USER',\n        'PASSWORD': '$POSTGRES_PASSWORD',\n        'HOST': 'localhost',\n        'PORT': '5432'," "${SETTINGS_FILE}"

cat <<EOL >> "${SETTINGS_FILE}"
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

# Gunicorn server script
cat > "$PROJECT_DIR/gunicorn_start.sh" <<EOL
#!/bin/bash
source /app/venv/bin/activate
cd /app/${APP_NAME}
exec gunicorn --workers 3 --bind 0.0.0.0:8000 $APP_NAME.wsgi:application
EOL

chmod +x "$PROJECT_DIR/gunicorn_start.sh"
    
# Configure Nginx
cat > "$PROJECT_DIR/nginx.conf" <<EOL
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
}
EOL

}

#if [ ! -d "$PROJECT_DIR" ]; then
#    init;
#fi

stop() {

    podman pod stop "$POD_NAME"
    podman pod rm "$POD_NAME"
}

start() {
    
    stop;

    # Create the pod
    podman pod create --name "$POD_NAME" --publish ${PORT}:${PORT} --publish 5050:5050 --network bridge
    
    # Start PostgreSQL container
    podman run --rm -d --pod "$POD_NAME" --name "$POSTGRES_CONTAINER_NAME" \
        -e POSTGRES_DB="$POSTGRES_DB" \
        -e POSTGRES_USER="$POSTGRES_USER" \
        -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
        -v "$PROJECT_DIR/db_data:/var/lib/postgresql/data" \
        "$POSTGRES_IMAGE"
    
    podman run --rm -d --pod "$POD_NAME" --name "$PGADMIN_CONTAINER_NAME" \
        -v "$PROJECT_DIR"/pgadmin:/var/lib/pgadmin:z \
        -e "PGADMIN_DEFAULT_EMAIL=dyka@brkh.work" \
        -e "PGADMIN_DEFAULT_PASSWORD=SuperSecret" \
        -e "PGADMIN_LISTEN_PORT=5050" \
        "$PGADMIN_IMAGE" 
    
    # Start Redis container
    podman run --rm -d --pod "$POD_NAME" --name "$REDIS_CONTAINER_NAME" \
        -v "$PROJECT_DIR/redis_data:/data" \
        "$REDIS_IMAGE"
    
    echo "Waiting database to ready"
    sleep 10
    # Run database migrations
    podman run --rm --pod "$POD_NAME" \
        -v "$PROJECT_DIR:/app" \
        -w /app/"$APP_NAME" \
        "$PYTHON_IMAGE" bash -c "source /app/venv/bin/activate && python manage.py migrate"
    
    podman run --rm -d --pod "$POD_NAME" --name "$GUNICORN_CONTAINER_NAME" \
        -v "$PROJECT_DIR:/app" -w /app \
        "$PYTHON_IMAGE" bash -c "./gunicorn_start.sh"
    
    
    podman run --rm -d --pod "$POD_NAME" --name "$NGINX_CONTAINER_NAME" \
        -v "$PROJECT_DIR/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
        "$NGINX_IMAGE"
    
    podman run --rm -d --pod "$POD_NAME" --name "${APP_NAME}"_cfltunnel \
        docker.io/cloudflare/cloudflared:latest tunnel --no-autoupdate run \
        --token eyJhIjoiNTdkZGI1MGYzMmI4ZTQ5ZTNmMWE0Mzg3MWVmMTQzZTciLCJ0IjoiODgzYWM1MzUtYjcxYi00MTg0LTkyNTItYTg5ZTkwNmQ0MWU1IiwicyI6IllqY3hZVE5qWldFdFptSmxZUzAwTnpGa0xXRm1PRFl0WVRBMk5EVXlNbVUzTWpVMiJ9
    
    echo "Django application setup complete. Access the app at http://$HOST_IP:8080 or https://dev.var.my.id/"

}

$1;
