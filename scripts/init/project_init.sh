#!/bin/bash

source "$(dirname "$0")/../config/config.sh"

# ---- Directory Setup -------
create_project_dirs() {
  local dirs=(
    "$PROJECT_DIR"
    "$SUPPORT_DIR"
    "$MAIN_DIR"
    "$ROOT_DIR"
    "$DJANGO_DIR"
    "$DJANGO_DIR/static"
    "$SUPPORT_DIR/db_data"
    "$SUPPORT_DIR/redis_data"
    "$SUPPORT_DIR/pgadmin"
    "$SUPPORT_DIR/logs"
  )

  echo "Creating project directories..."
  for dir in "${dirs[@]}"; do
    [ ! -d "$dir" ] && mkdir -p "$dir"
  done

  # Create token file if it doesn't exist
  [ ! -f "$SUPPORT_DIR/token" ] && touch "$SUPPORT_DIR/token"
  chmod 777 "$SUPPORT_DIR/pgadmin"
}

# ---- Virtual Environment Setup -------
setup_virtualenv() {
  echo "Creating Python virtual environment and installing requirements..."
  podman run --rm -v "$PROJECT_DIR:/app:z" -v "$ROOT_DIR:/root:z" "$PYTHON_IMAGE" bash -c "
    apt-get update && \
    apt-get install -y curl build-essential && \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
    . \$HOME/.cargo/env && \
    python -m venv /app/support/venv && \
    source /app/support/venv/bin/activate && \
    pip install --upgrade pip && \
    pip install -r /app/support/requirements.txt"
}

# ---- Django Setup -------
init_django() {
  echo "Initializing Django project..."
  podman run -it --rm -v "$PROJECT_DIR:/app:z" "$PYTHON_IMAGE" bash -c "
    source /app/support/venv/bin/activate && \
    cd /app/django_auth && \
    django-admin startproject auth_project . && \
    python manage.py startapp authentication"
}

# ---- Alembic Setup -------
init_alembic() {
  echo "Initializing Alembic..."
  podman run --rm -v "$PROJECT_DIR:/app:z" -w /app "$PYTHON_IMAGE" bash -c "
    source /app/support/venv/bin/activate && \
    cd /app/support && \
    pip install alembic && \
    alembic init migrations"

  # Update alembic.ini with correct database URL
  local ESCAPED_PASSWORD=$(printf '%s\n' "$POSTGRES_PASSWORD" | sed -e 's/[\/&]/\\&/g')
  sed -i "s|sqlalchemy.url = driver://user:pass@localhost/dbname|sqlalchemy.url = postgresql://${POSTGRES_USER}:${ESCAPED_PASSWORD}@${POSTGRES_CONTAINER_NAME}:5432/${POSTGRES_DB}|g" \
    "$SUPPORT_DIR/alembic.ini"
}

# ---- Database Management -------
run_migrations() {
  echo "Running database migrations..."

  # Export environment variables for Alembic
  export POSTGRES_CONTAINER_NAME POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB

  # Run Django migrations
  echo "Running Django migrations..."
  podman run -it --rm --pod "$POD_NAME" \
    -v "$PROJECT_DIR:/app:z" \
    -e "POSTGRES_CONTAINER_NAME=$POSTGRES_CONTAINER_NAME" \
    -e "POSTGRES_USER=$POSTGRES_USER" \
    -e "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" \
    -e "POSTGRES_DB=$POSTGRES_DB" \
    -w /app/django_auth \
    "$PYTHON_IMAGE" bash -c \
    "source /app/support/venv/bin/activate && \
     python manage.py makemigrations && \
     python manage.py migrate"

  sleep 5

  # Run Alembic migrations
  echo "Running FastAPI/Alembic migrations..."
  podman run -it --rm --pod "$POD_NAME" \
    -v "$PROJECT_DIR:/app:z" \
    -w /app/support \
    -e "POSTGRES_CONTAINER_NAME=$POSTGRES_CONTAINER_NAME" \
    -e "POSTGRES_USER=$POSTGRES_USER" \
    -e "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" \
    -e "POSTGRES_DB=$POSTGRES_DB" \
    -e "PYTHONPATH=/app" \
    "$PYTHON_IMAGE" bash -c \
    "source /app/support/venv/bin/activate && \
     rm -rf migrations/versions/* && \
     alembic revision --autogenerate -m 'initial' && \
     alembic upgrade head"

  echo "Database migrations completed."
}

# ---- Project Initialization -------
initialize_project() {
  [ -d "$PROJECT_DIR" ] && echo "Warning: Project directory already exists. Some files may be overwritten."
  
  create_project_dirs
  create_project_files
  setup_virtualenv
  init_django
  sleep 10  # Wait for Django files to be created
  create_django_files
  init_alembic
  create_alembic_files
}