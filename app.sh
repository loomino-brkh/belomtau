#!/bin/bash

# Variables
PROJECT_NAME="lomtau"
PROJECT_DIR="./$PROJECT_NAME"
DB_NAME="$PROJECT_NAME-database"
DB_USER="$PROJECT_NAME"
DB_PASS="superkeren"
DB_CONTAINER_NAME="$PROJECT_NAME-postgresql"
REDIS_CONTAINER_NAME="$PROJECT_NAME-redis"
WEB_CONTAINER_NAME="$PROJECT_NAME-web"
POD_NAME="$PROJECT_NAME-pod"

# Create a new Django project with PostgreSQL and Redis using Podman
function create_django_project() {
    # Create Django project directory
    mkdir -p $PROJECT_DIR
    cd $PROJECT_DIR || exit

    # Initialize Django project
    podman run --rm -v $PWD:/app:z -w /app python bash -c "pip install django && django-admin startproject $PROJECT_NAME ."

    # Generate Dockerfile for Django app
    cat <<EOF > Dockerfile
FROM python

WORKDIR /app
COPY . /app

RUN pip install -r requirements.txt

CMD ["python", "manage.py", "runserver", "0.0.0.0:8000"]
EOF

    # Generate requirements.txt
    echo "django\npsycopg2\nredis" > requirements.txt

    # Update Django settings
    sed -i "s/'ENGINE': 'django.db.backends.sqlite3'/'ENGINE': 'django.db.backends.postgresql'/g" $PROJECT_NAME/settings.py
    sed -i "s/'NAME': BASE_DIR / 'db.sqlite3'/'NAME': '$DB_NAME'/g" $PROJECT_NAME/settings.py
    sed -i "s/# 'USER': 'mydatabaseuser'/'USER': '$DB_USER'/g" $PROJECT_NAME/settings.py
    sed -i "s/# 'PASSWORD': 'mypassword'/'PASSWORD': '$DB_PASS'/g" $PROJECT_NAME/settings.py
    sed -i "s/# 'HOST': 'localhost'/'HOST': 'db'/g" $PROJECT_NAME/settings.py
    sed -i "s/# 'PORT': '5432'/'PORT': '5432'/g" $PROJECT_NAME/settings.py

    # Configure Redis as cache backend
    cat <<EOF >> $PROJECT_NAME/settings.py
CACHES = {
    'default': {
        'BACKEND': 'django_redis.cache.RedisCache',
        'LOCATION': 'redis://redis:6379/1',
        'OPTIONS': {
            'CLIENT_CLASS': 'django_redis.client.DefaultClient',
        }
    }
}
EOF
    echo "Django project created successfully!"
}

# Deploy the Pod with PostgreSQL and Redis
function deploy_pod() {
    podman pod create --name $POD_NAME -p 8000:8000

    # PostgreSQL container
    podman run -d --pod $POD_NAME --name $DB_CONTAINER_NAME \
        -e POSTGRES_DB=$DB_NAME \
        -e POSTGRES_USER=$DB_USER \
        -e POSTGRES_PASSWORD=$DB_PASS \
        postgres:16

    # Redis container
    podman run -d --pod $POD_NAME --name $REDIS_CONTAINER_NAME redis:latest

    # Django web container
    podman build -t django_web .
    podman run -d --pod $POD_NAME --name $WEB_CONTAINER_NAME \
        -v $PWD:/app:z -w /app django_web

    echo "Pod deployed successfully!"
}

# Start the Pod
function start_pod() {
    podman pod start $POD_NAME
    echo "Pod started successfully!"
}

# Stop the Pod
function stop_pod() {
    podman pod stop $POD_NAME
    echo "Pod stopped successfully!"
}

# Destroy the Pod
function destroy_pod() {
    podman pod rm -f $POD_NAME
    echo "Pod destroyed successfully!"
}

# Export the database
function export_db() {
    podman exec -t $DB_CONTAINER_NAME pg_dump -U $DB_USER $DB_NAME > db_backup.sql
    echo "Database exported successfully!"
}

# Import the database
function import_db() {
    if [ ! -f db_backup.sql ]; then
        echo "Database backup file not found!"
        exit 1
    fi
    podman exec -i $DB_CONTAINER_NAME psql -U $DB_USER $DB_NAME < db_backup.sql
    echo "Database imported successfully!"
}

# Watch for changes in the development directory
function watch_directory() {
    inotifywait -m -e modify,create,delete ./ |
    while read -r directory events filename; do
        echo "Change detected in $filename ($events). Restarting Django server..."
        podman restart $WEB_CONTAINER_NAME
    done
}

# Command line arguments
case "$1" in
    create)
        create_django_project
        ;;
    deploy)
        deploy_pod
        ;;
    start)
        start_pod
        ;;
    stop)
        stop_pod
        ;;
    destroy)
        destroy_pod
        ;;
    export)
        export_db
        ;;
    import)
        import_db
        ;;
    watch)
        watch_directory
        ;;
    *)
        echo "Usage: $0 {create|deploy|start|stop|destroy|export|import|watch}"
        ;;
esac
