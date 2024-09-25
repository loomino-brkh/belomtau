#!/bin/bash

# ---- Configuration -------
APP_NAME="$2"
PROJECT_DIR="$HOME/project_${APP_NAME}"
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

# Create virtualenv 
podman run --rm -v "$PROJECT_DIR:/app" "$PYTHON_IMAGE" python -m venv /app/venv

# Activate virtualenv and install requirements
podman run --rm -v "$PROJECT_DIR:/app" -w /app "$PYTHON_IMAGE" bash -c "source /app/venv/bin/activate && pip install --upgrade pip && pip install -r /app/requirements.txt"

# Create Django project 
podman run --rm -v "$PROJECT_DIR:/app" -w /app "$PYTHON_IMAGE" bash -c "/app/venv/bin/django-admin startproject $APP_NAME"

sed -i "s/ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = \[/g" "${SETTINGS_FILE}"
sed -i "/ALLOWED_HOSTS = \[/a\     '$HOST_IP',\n     'dev.var.my.id',\n\]" "${SETTINGS_FILE}"

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

# Create initial API app
podman run --rm -v "$PROJECT_DIR:/app" -w /app "$PYTHON_IMAGE" bash -c "source /app/venv/bin/activate && python manage.py startapp api"

# Add 'api' to INSTALLED_APPS
sed -i "/INSTALLED_APPS = \[/a\    'api'," "${SETTINGS_FILE}"

# Create serializers.py in api app
podman run --rm -v "$PROJECT_DIR:/app" -w /app "$PYTHON_IMAGE" bash -c "echo \"from rest_framework import serializers

from .models import YourModel

class YourModelSerializer(serializers.ModelSerializer):
    class Meta:
        model = YourModel
        fields = '__all__'
\" > api/serializers.py"

# Create views.py with basic API view
podman run --rm -v "$PROJECT_DIR:/app" -w /app "$PYTHON_IMAGE" bash -c "echo \"from rest_framework import viewsets
from .models import YourModel
from .serializers import YourModelSerializer

class YourModelViewSet(viewsets.ModelViewSet):
    queryset = YourModel.objects.all()
    serializer_class = YourModelSerializer
\" > api/views.py"

# Create urls.py in api app
podman run --rm -v "$PROJECT_DIR:/app" -w /app "$PYTHON_IMAGE" bash -c "echo \"from django.urls import path, include
from rest_framework import routers
from . import views

router = routers.DefaultRouter()
router.register(r'yourmodel', views.YourModelViewSet)

urlpatterns = [
    path('', include(router.urls)),
]
\" > api/urls.py"

# Include api.urls in project's urls.py
sed -i "/from django.urls import path/a\from django.urls import include" "${PROJECT_DIR}/${APP_NAME}/${APP_NAME}/urls.py"
sed -i "/urlpatterns = \[/a\    path('api/', include('api.urls'))," "${PROJECT_DIR}/${APP_NAME}/${APP_NAME}/urls.py"

# Gunicorn server script
cat > "$PROJECT_DIR/gunicorn_start.sh" <<EOL
#!/bin/bash
source /app/venv/bin/activate
cd /app/${APP_NAME}
exec gunicorn --reload --workers 10 --bind 0.0.0.0:8000 $APP_NAME.wsgi:application
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
    podman pod rm "$POD_NAME"
}

start() {
    
    stop;

    # Create the pod
    podman pod create --name "$POD_NAME" --publish ${PORT}:8000 --publish 5050:5050 --network bridge
    
    # Start PostgreSQL container
    podman run --rm -d --pod "$POD_NAME" --name "$POSTGRES_CONTAINER_NAME" \
        -e POSTGRES_DB="$POSTGRES_DB" \
        -e POSTGRES_USER="$POSTGRES_USER" \
        -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
        -v "$PROJECT_DIR/db_data:/var/lib/postgresql/data:z" \
        "$POSTGRES_IMAGE"
    
    # Start pgAdmin container
    podman run --rm -d --pod "$POD_NAME" --name "$PGADMIN_CONTAINER_NAME" \
        -e "PGADMIN_DEFAULT_EMAIL=dyka@brkh.work" \
        -e "PGADMIN_DEFAULT_PASSWORD=SuperSecret" \
        -e "PGADMIN_LISTEN_PORT=5050" \
        -v "$PROJECT_DIR/pgadmin:/var/lib/pgadmin:z" \
        "$PGADMIN_IMAGE" 
    
    # Start Redis container
    podman run --rm -d --pod "$POD_NAME" --name "$REDIS_CONTAINER_NAME" \
        -v "$PROJECT_DIR/redis_data:/data:z" \
        "$REDIS_IMAGE"
    
    echo "Waiting for database to be ready..."
    sleep 15

    # Run database migrations
    podman run --rm --pod "$POD_NAME" \
        -v "$PROJECT_DIR:/app:ro" \
        -w /app/"$APP_NAME" \
        "$PYTHON_IMAGE" bash -c "source /app/venv/bin/activate && python manage.py migrate"
    
    # Collect static files
    podman run --rm --pod "$POD_NAME" \
        -v "$PROJECT_DIR:/app:ro" \
        -w /app/"$APP_NAME" \
        "$PYTHON_IMAGE" bash -c "source /app/venv/bin/activate && python manage.py collectstatic --noinput"
    
    # Start Gunicorn container
    podman run --rm -d --pod "$POD_NAME" --name "$GUNICORN_CONTAINER_NAME" \
        -v "$PROJECT_DIR:/app:ro" -w /app \
        "$PYTHON_IMAGE" bash -c "./gunicorn_start.sh"
    
    # Start Nginx container
    podman run --rm -d --pod "$POD_NAME" --name "$NGINX_CONTAINER_NAME" \
        -v "$PROJECT_DIR/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
        -v "$PROJECT_DIR/staticfiles:/www/staticfiles:ro" \
        "$NGINX_IMAGE"
    
    # Start interactive container (optional)
    podman run --rm -d --pod "$POD_NAME" --name "${APP_NAME}_interact" \
        -v "$PROJECT_DIR":/app:z \
        -v "$PROJECT_DIR"/.root:/root:z \
        -v /usr/bin/cloudflared:/usr/bin/cloudflared \
        -w "/app/${APP_NAME}" \
        "$PYTHON_IMAGE" sleep infinity
    
    # Start Cloudflare tunnel container (replace <TOKEN> with your actual token)
    podman run --rm -d --pod "$POD_NAME" --name "${APP_NAME}_cfltunnel" \
        docker.io/cloudflare/cloudflared:latest tunnel --no-autoupdate run \
        --token eyJhIjoiNTdkZGI1MGYzMmI4ZTQ5ZTNmMWE0Mzg3MWVmMTQzZTciLCJ0IjoiODgzYWM1MzUtYjcxYi00MTg0LTkyNTItYTg5ZTkwNmQ0MWU1IiwicyI6IllqY3hZVE5qWldFdFptSmxZUzAwTnpGa0xXRm1PRFl0WVRBMk5EVXlNbVUzTWpVMiJ9
    
    echo "Django RESTful API application setup complete."
    echo "Access the API at http://${HOST_IP}:${PORT}/api/ or https://dev.var.my.id/api/"

}

$1;
