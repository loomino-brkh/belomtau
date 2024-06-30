#!/bin/bash

# Configuration
APP_NAME="lomtau"
PROJECT_DIR="$HOME/django_lomtau"
VENV_DIR="$PROJECT_DIR/venv"
HOST_IP="192.168.22.10"
POD_NAME="${APP_NAME}_pod"
POSTGRES_IMAGE="docker.io/library/postgres:16"
PYTHON_IMAGE="docker.io/library/python:latest"
REDIS_IMAGE="docker.io/library/redis:latest"
NGINX_IMAGE="docker.io/library/nginx:latest"
POSTGRES_DB="${APP_NAME}_db"
POSTGRES_USER="${APP_NAME}_user"
POSTGRES_PASSWORD="supersecure"
DJANGO_SETTINGS_MODULE="${APP_NAME}.settings"
REQUIREMENTS_FILE="$PROJECT_DIR/requirements.txt"

# Create project directory if it doesn't exist
mkdir -p "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/db_data"

# Create requirements.txt if it doesn't exist
cat > "$REQUIREMENTS_FILE" <<EOL
Django>=4.0
psycopg2-binary
gunicorn
django-redis
EOL

# Create virtualenv if it doesn't exist
if [ ! -d "$VENV_DIR" ]; then
    podman run --rm -v "$PROJECT_DIR:/app" "$PYTHON_IMAGE" python -m venv /app/venv
fi

# Activate virtualenv and install requirements

podman run --rm -v "$PROJECT_DIR:/app" -w /app "$PYTHON_IMAGE" bash -c "source /app/venv/bin/activate && pip install -r /app/requirements.txt"

# Create Django project if it doesn't exist
if [ ! -d "$PROJECT_DIR/$APP_NAME" ]; then
    podman run --rm -v "$PROJECT_DIR:/app" -w /app "$PYTHON_IMAGE" bash -c "/app/venv/bin/django-admin startproject $APP_NAME"
fi

# Create the pod
podman pod create --name "$POD_NAME" --publish 8080:8080 --network bridge

# Start PostgreSQL container
podman run --rm -d --pod "$POD_NAME" --name postgres \
    -e POSTGRES_DB="$POSTGRES_DB" \
    -e POSTGRES_USER="$POSTGRES_USER" \
    -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
    -v "$PROJECT_DIR/db_data:/var/lib/postgresql/data" \
    "$POSTGRES_IMAGE"

# Start Redis container
podman run --rm -d --pod "$POD_NAME" --name redis \
    -v redis_data:/data \
    "$REDIS_IMAGE"

# Configure Django settings
SETTINGS_FILE="$PROJECT_DIR/$APP_NAME/$APP_NAME/settings.py"

cp -f $PWD/settings.py $SETTINGS_FILE

# Run database migrations
podman run --rm --pod "$POD_NAME" -v "$PROJECT_DIR:/app" -w /app/$APP_NAME "$PYTHON_IMAGE" bash -c "source /app/venv/bin/activate && python manage.py migrate"

# Start Gunicorn server
cat > "$PROJECT_DIR/gunicorn_start.sh" <<EOL
#!/bin/bash
source /app/venv/bin/activate
cd /app/${APP_NAME}
exec gunicorn --workers 3 --bind 0.0.0.0:8000 $APP_NAME.wsgi:application
EOL
chmod +x "$PROJECT_DIR/gunicorn_start.sh"

podman run --rm -d --pod "$POD_NAME" --name gunicorn \
    -v "$PROJECT_DIR:/app" -w /app "$PYTHON_IMAGE" bash -c "./gunicorn_start.sh"

# Configure and start Nginx
cat > "$PROJECT_DIR/nginx.conf" <<EOL
server {
    listen 8080;
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

podman run --rm -d --pod "$POD_NAME" --name nginx \
    -v "$PROJECT_DIR/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
    "$NGINX_IMAGE"

echo "Django application setup complete. Access the app at http://$HOST_IP:8080"
