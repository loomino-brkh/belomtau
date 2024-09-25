#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# ---- Configuration -------
APP_NAME="$2"
# Replace hyphens with underscores to create a valid Python module name
VALID_APP_NAME=$(echo "$APP_NAME" | tr '-' '_')
PROJECT_DIR="$HOME/eskrim/project_${APP_NAME}"
#VENV_DIR="${PROJECT_DIR}/venv"

HOST_IP="192.168.100.77"
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

# SETTINGS_FILE_MODULE="${APP_NAME}.settings"
REQUIREMENTS_FILE="${PROJECT_DIR}/requirements.txt"
SETTINGS_FILE="${PROJECT_DIR}/${VALID_APP_NAME}/settings.py"

# ---- Configuration -------

init() {

    echo "Initializing Django RESTful API project: ${APP_NAME}"
    
    # Create project directory 
    mkdir -p "$PROJECT_DIR"
    mkdir -p "$PROJECT_DIR/db_data"
    mkdir -p "$PROJECT_DIR/redis_data"
    mkdir -p "$PROJECT_DIR/pgadmin"
    mkdir -p "$PROJECT_DIR/.root"

    chmod 777 "$PROJECT_DIR/pgadmin"

    # Create requirements.txt 
    cat > "$REQUIREMENTS_FILE" <<EOL
Django>=4.0
djangorestframework
psycopg2-binary
gunicorn
django-redis
EOL

    echo "Created requirements.txt"

    # Create virtualenv 
    podman run --rm -v "$PROJECT_DIR:/app" "$PYTHON_IMAGE" python -m venv /app/venv

    echo "Created virtual environment"

    # Activate virtualenv and install requirements
    podman run --rm -v "$PROJECT_DIR:/app" -w /app "$PYTHON_IMAGE" bash -c "source /app/venv/bin/activate && pip install --upgrade pip && pip install -r /app/requirements.txt"

    echo "Installed requirements"

    # Create Django project 
    podman run --rm -v "$PROJECT_DIR:/app" -w /app "$PYTHON_IMAGE" bash -c "/app/venv/bin/django-admin startproject $VALID_APP_NAME"

    echo "Created Django project: $VALID_APP_NAME"

    # Verify that settings.py exists
    if [ ! -f "$SETTINGS_FILE" ]; then
        echo "Error: settings.py not found at $SETTINGS_FILE"
        exit 1
    fi

    echo "Django settings.py found"

    # Update settings.py for allowed hosts and database configurations
    sed -i "s/ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = \[/g" "${SETTINGS_FILE}"
    sed -i "/ALLOWED_HOSTS = \[/a\    '$HOST_IP',\n    'dev.var.my.id',\n]" "${SETTINGS_FILE}"

    sed -i "s/'ENGINE': 'django.db.backends.sqlite3'/'ENGINE': 'django.db.backends.postgresql'/g" "${SETTINGS_FILE}"
    sed -i "s/'NAME': BASE_DIR \/ 'db.sqlite3'/'NAME': '$POSTGRES_DB'/g" "${SETTINGS_FILE}"
    sed -i "/'NAME': '$POSTGRES_DB'/a\        'USER': '$POSTGRES_USER',\n        'PASSWORD': '$POSTGRES_PASSWORD',\n        'HOST': 'localhost',\n        'PORT': '5432'," "${SETTINGS_FILE}"

    # Add Django REST Framework to INSTALLED_APPS
    sed -i "/INSTALLED_APPS = \[/a\    'rest_framework'," "${SETTINGS_FILE}"

    # Add CACHES configuration
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

    echo "Updated settings.py with allowed hosts, database config, REST framework, and Caches"

    # Add REST framework default settings
    cat <<EOL >> "${SETTINGS_FILE}"
REST_FRAMEWORK = {
    'DEFAULT_PERMISSION_CLASSES': [
        'rest_framework.permissions.AllowAny',
    ],
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'rest_framework.authentication.SessionAuthentication',
        'rest_framework.authentication.BasicAuthentication',
    ],
}
EOL

    echo "Added REST framework default settings"

    # Create initial API app within the Django project directory
    podman run --rm -v "$PROJECT_DIR:/app" -w /app/"$VALID_APP_NAME" "$PYTHON_IMAGE" bash -c "source /app/venv/bin/activate && python manage.py startapp api"

    echo "Created 'api' app"

    # Define API App Directory
    API_APP_DIR="${PROJECT_DIR}/${VALID_APP_NAME}/api"

    # Ensure the api app directory exists
    if [ ! -d "$API_APP_DIR" ]; then
        echo "Error: API app directory not found at $API_APP_DIR"
        exit 1
    fi

    echo "'api' app directory exists"

    # Add 'api' to INSTALLED_APPS
    sed -i "/INSTALLED_APPS = \[/a\    'api'," "${SETTINGS_FILE}"

    echo "Added 'api' to INSTALLED_APPS"

    # Create serializers.py in api app
    podman run --rm -v "$PROJECT_DIR:/app" -w /app/"$VALID_APP_NAME"/api "$PYTHON_IMAGE" bash -c "echo \"from rest_framework import serializers

from .models import YourModel

class YourModelSerializer(serializers.ModelSerializer):
    class Meta:
        model = YourModel
        fields = '__all__'
\" > serializers.py"

    echo "Created serializers.py"

    # Create views.py with basic API view
    podman run --rm -v "$PROJECT_DIR:/app" -w /app/"$VALID_APP_NAME"/api "$PYTHON_IMAGE" bash -c "echo \"from rest_framework import viewsets
from .models import YourModel
from .serializers import YourModelSerializer

class YourModelViewSet(viewsets.ModelViewSet):
    queryset = YourModel.objects.all()
    serializer_class = YourModelSerializer
\" > views.py"

    echo "Created views.py"

    # Create urls.py in api app
    podman run --rm -v "$PROJECT_DIR:/app" -w /app/"$VALID_APP_NAME"/api "$PYTHON_IMAGE" bash -c "echo \"from django.urls import path, include
from rest_framework import routers
from . import views

router = routers.DefaultRouter()
router.register(r'yourmodel', views.YourModelViewSet)

urlpatterns = [
    path('', include(router.urls)),
]
\" > urls.py"

    echo "Created urls.py"

    # Include api.urls in project's urls.py
    sed -i "/from django.urls import path/a\from django.urls import include" "${PROJECT_DIR}/${VALID_APP_NAME}/urls.py"
    sed -i "/urlpatterns = \[/a\    path('api/', include('api.urls'))," "${PROJECT_DIR}/${VALID_APP_NAME}/urls.py"

    echo "Included 'api.urls' in project urls.py"

    # Gunicorn server script
    cat > "$PROJECT_DIR/gunicorn_start.sh" <<EOL
#!/bin/bash
source /app/venv/bin/activate
cd /app/${VALID_APP_NAME}
exec gunicorn --reload --workers 10 --bind 0.0.0.0:8000 ${VALID_APP_NAME}.wsgi:application
EOL

    chmod +x "$PROJECT_DIR/gunicorn_start.sh"

    echo "Created gunicorn_start.sh"

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

    location /api/ {
        proxy_pass http://127.0.0.1:8000/api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

    echo "Configured Nginx"

    # Verify project structure
    echo "Verifying project structure..."
    ls -la "$PROJECT_DIR/$VALID_APP_NAME"

    echo "Initialization complete."
}

stop() {
    echo "Stopping pod: $POD_NAME"
    podman pod stop "$POD_NAME" || echo "Pod not running."
    podman pod rm "$POD_NAME" || echo "Pod not found."
}

start() {
    
    echo "Starting Django RESTful API application..."

    stop

    # Create the pod
    podman pod create --name "$POD_NAME" --publish ${PORT}:8000 --publish 5050:5050 --network bridge

    echo "Created pod: $POD_NAME"

    # Start PostgreSQL container
    podman run --rm -d --pod "$POD_NAME" --name "$POSTGRES_CONTAINER_NAME" \
        -e POSTGRES_DB="$POSTGRES_DB" \
        -e POSTGRES_USER="$POSTGRES_USER" \
        -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
        -v "$PROJECT_DIR/db_data:/var/lib/postgresql/data:z" \
        "$POSTGRES_IMAGE"

    echo "Started PostgreSQL container"

    # Start pgAdmin container
    podman run --rm -d --pod "$POD_NAME" --name "$PGADMIN_CONTAINER_NAME" \
        -e "PGADMIN_DEFAULT_EMAIL=dyka@brkh.work" \
        -e "PGADMIN_DEFAULT_PASSWORD=SuperSecret" \
        -e "PGADMIN_LISTEN_PORT=5050" \
        -v "$PROJECT_DIR/pgadmin:/var/lib/pgadmin:z" \
        "$PGADMIN_IMAGE" 

    echo "Started pgAdmin container"

    # Start Redis container
    podman run --rm -d --pod "$POD_NAME" --name "$REDIS_CONTAINER_NAME" \
        -v "$PROJECT_DIR/redis_data:/data:z" \
        "$REDIS_IMAGE"

    echo "Started Redis container"

    echo "Waiting for PostgreSQL to be ready..."
    sleep 15

    # Run database migrations
    podman run --rm --pod "$POD_NAME" \
        -v "$PROJECT_DIR:/app" \
        -w /app/"$VALID_APP_NAME" \
        "$PYTHON_IMAGE" bash -c "source /app/venv/bin/activate && python manage.py migrate"

    echo "Ran database migrations"

    # Collect static files
    podman run --rm --pod "$POD_NAME" \
        -v "$PROJECT_DIR:/app" \
        -w /app/"$VALID_APP_NAME" \
        "$PYTHON_IMAGE" bash -c "source /app/venv/bin/activate && python manage.py collectstatic --noinput"

    echo "Collected static files"

    # Start Gunicorn container
    podman run --rm -d --pod "$POD_NAME" --name "$GUNICORN_CONTAINER_NAME" \
        -v "$PROJECT_DIR:/app:ro" -w /app \
        "$PYTHON_IMAGE" bash -c "./gunicorn_start.sh"

    echo "Started Gunicorn container"

    # Start Nginx container
    podman run --rm -d --pod "$POD_NAME" --name "$NGINX_CONTAINER_NAME" \
        -v "$PROJECT_DIR/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
        -v "$PROJECT_DIR/staticfiles:/www/staticfiles:ro" \
        "$NGINX_IMAGE"

    echo "Started Nginx container"

    # Start interactive container (optional)
    podman run --rm -d --pod "$POD_NAME" --name "${APP_NAME}_interact" \
        -v "$PROJECT_DIR":/app:z \
        -v "$PROJECT_DIR"/.root:/root:z \
        -v /usr/bin/cloudflared:/usr/bin/cloudflared \
        -w "/app/${VALID_APP_NAME}" \
        "$PYTHON_IMAGE" sleep infinity

    echo "Started interactive container"

    # Start Cloudflare tunnel container (replace <TOKEN> with your actual token)
    podman run --rm -d --pod "$POD_NAME" --name "${APP_NAME}_cfltunnel" \
        docker.io/cloudflare/cloudflared:latest tunnel --no-autoupdate run \
        --token eyJhIjoiNTdkZGI1MGYzMmI4ZTQ5ZTNmMWE0Mzg3MWVmMTQzZTciLCJ0IjoiODgzYWM1MzUtYjcxYi00MTg0LTkyNTItYTg5ZTkwNmQ0MWU1IiwicyI6IllqY3hZVE5qWldFdFptSmxZUzAwTnpGa0xXRm1PRFl0WVRBMk5EVXlNbVUzTWpVMiJ9

    echo "Started Cloudflare tunnel container"

    echo "Django RESTful API application setup complete."
    echo "Access the API at http://${HOST_IP}:${PORT}/api/ or https://dev.var.my.id/api/"
}

# Main Execution
case "$1" in
    init)
        init
        ;;
    start)
        start
        ;;
    stop)
        stop
        ;;
    *)
        echo "Usage: $0 {init|start|stop} <app_name>"
        exit 1
        ;;
esac
