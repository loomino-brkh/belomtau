#!/bin/bash

# Variables
PROJECT_DIR="$HOME/my_django_project"
VENV_DIR="${PROJECT_DIR}/venv"
DJANGO_DIR="${PROJECT_DIR}/myapp"
REQUIREMENTS_FILE="${PROJECT_DIR}/requirements.txt"
POSTGRES_VOL="${PROJECT_DIR}/postgres_data"
HOST_IP="192.168.22.10"
PORT="8080"
POD_NAME="django_pod"

# Function to create the environment
create_env() {
    echo "Creating project structure and virtual environment..."
    
    # Create necessary directories
    mkdir -p "${PROJECT_DIR}"
    mkdir -p "${POSTGRES_VOL}"
    
    # Create virtual environment if not exists
    if [ ! -d "${VENV_DIR}" ]; then
        podman run --rm -v "${PROJECT_DIR}":/project:z python:latest bash -c "cd /project && python -m venv venv"
        echo "Virtual environment created at ${VENV_DIR}"
    else
        echo "Virtual environment already exists at ${VENV_DIR}"
    fi

    # Create requirements.txt if not exists
    if [ ! -f "${REQUIREMENTS_FILE}" ]; then
        cat <<EOL > "${REQUIREMENTS_FILE}"
Django>=3.2
psycopg2-binary
redis
gunicorn
EOL
        echo "requirements.txt created at ${REQUIREMENTS_FILE}"
    fi

    # Install dependencies in virtual environment
    podman run --rm -v "${PROJECT_DIR}":/project:z python:latest bash -c "cd /project && ./venv/bin/pip install -r requirements.txt"

    # Create Django project if not exists
    if [ ! -d "${DJANGO_DIR}" ]; then
        podman run --rm -v "${PROJECT_DIR}":/project:z python:latest bash -c "cd /project && ./venv/bin/django-admin startproject myapp"
        echo "Django project created at ${DJANGO_DIR}"
    else
        echo "Django project already exists at ${DJANGO_DIR}"
    fi
}

# Function to configure Django settings
configure_django() {
    DJANGO_SETTINGS="${DJANGO_DIR}/myapp/settings.py"
    
    echo "Configuring Django settings..."
    sed -i "s/'ENGINE': 'django.db.backends.sqlite3'/'ENGINE': 'django.db.backends.postgresql'/g" ${DJANGO_SETTINGS}
    sed -i "s/'NAME': BASE_DIR \/ 'db.sqlite3'/'NAME': 'django'/g" ${DJANGO_SETTINGS}
    sed -i "/'NAME': 'django'/a\        'USER': 'django',\n        'PASSWORD': 'django',\n        'HOST': 'localhost',\n        'PORT': '5432'," ${DJANGO_SETTINGS}
    
    cat <<EOL >> ${DJANGO_SETTINGS}
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
}

# Function to run the application
run_app() {
    echo "Running Django app in a pod..."
    
    # Create pod
    podman pod create --name ${POD_NAME} -p ${PORT}:80

    # Start PostgreSQL and Redis containers
    podman run -d --pod ${POD_NAME} --name postgres -e POSTGRES_USER=django -e POSTGRES_PASSWORD=django -e POSTGRES_DB=django -v "${POSTGRES_VOL}":/var/lib/postgresql/data:z postgres:16
    podman run -d --pod ${POD_NAME} --name django_redis redis:latest

    # Configure Django
    configure_django

    # Run database migrations
    podman run --rm -v "${PROJECT_DIR}":/project:z -w /project/myapp --pod ${POD_NAME} python:latest bash -c "source /project/venv/bin/activate && python manage.py migrate"

    # Run Django app with Gunicorn
    podman run -d --pod ${POD_NAME} --name django -v "${PROJECT_DIR}":/project:z -w /project/myapp python:latest bash -c "source /project/venv/bin/activate && gunicorn --bind 0.0.0.0:8000 myapp.wsgi:application"

    # Configure and run Nginx
    cat <<EOL > "${PROJECT_DIR}/nginx.conf"
server {
    listen 80;
    server_name ${HOST_IP};

    location / {
        proxy_pass http://localhost:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /static/ {
        alias /project/myapp/static/;
    }

    location /media/ {
        alias /project/myapp/media/;
    }
}
EOL
    podman run -d --pod ${POD_NAME} --name django_nginx -v "${PROJECT_DIR}/nginx.conf":/etc/nginx/nginx.conf:ro nginx:latest
}

# Function to clean up
clean_up() {
    echo "Cleaning up the pod and containers..."
    podman pod stop ${POD_NAME}
    podman pod rm ${POD_NAME}
    podman volume prune -f
    echo "All components destroyed."
}

# Check script arguments
case $1 in
    create)
        create_env
        ;;
    run)
        run_app
        ;;
    clean)
        clean_up
        ;;
    *)
        echo "Usage: $0 {create|run|clean}"
        ;;
esac
