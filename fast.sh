#!/bin/bash
# ---- Configuration -------
HOST_DOMAIN="dev.var.my.id"
PORT1="8080"  # Nginx port
PORT2="8000"  # FastAPI port
PORT3="8001"  # Django port

# Check if command argument is provided
if [ -z "$1" ]; then
    echo "Error: Command argument is required"
    echo "Usage: $0 <command> <app_name>"
    echo "Commands: init, start, stop, cek, pg, db, rev"
    exit 1
fi

# Check if app name is provided
if [ -z "$2" ]; then
    echo "Error: App name is required"
    echo "Usage: $0 <command> <app_name>"
    exit 1
fi

# Check if podman is installed
if ! command -v podman &> /dev/null; then
    echo "Error: podman is not installed"
    exit 1
fi

APP_NAME="$2"
PROJECT_DIR="$HOME/fast_projects/api_${APP_NAME}"
SUPPORT_DIR="${PROJECT_DIR}/support"
MAIN_DIR="${PROJECT_DIR}/main"
DJANGO_DIR="${PROJECT_DIR}/django_auth"

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
UVICORN_CONTAINER_NAME="${APP_NAME}_uvicorn"
DJANGO_CONTAINER_NAME="${APP_NAME}_django"
NGINX_CONTAINER_NAME="${APP_NAME}_nginx"
PGADMIN_CONTAINER_NAME="${APP_NAME}_pgadmin"
CFL_TUNNEL_CONTAINER_NAME="${APP_NAME}_cfltunnel"
INTERACT_CONTAINER_NAME="${APP_NAME}_interact"

REQUIREMENTS_FILE="${SUPPORT_DIR}/requirements.txt"
MAIN_FILE="${MAIN_DIR}/main.py"
DB_FILE="${MAIN_DIR}/db.py"
SCHEMAS_FILE="${MAIN_DIR}/schemas.py"

rev() {
  echo "Creating Python virtual environment and installing requirements..."
  podman run --rm -v "$PROJECT_DIR:/app:z" "$PYTHON_IMAGE" bash -c "
    apt-get update && \
    apt-get install -y curl build-essential && \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
    . \$HOME/.cargo/env && \
    python -m venv /app/support/venv && \
    source /app/support/venv/bin/activate && \
    pip install --upgrade pip && \
    pip install -r /app/support/requirements.txt"
}

init() {
  # Check if project directory already exists
  if [ -d "$PROJECT_DIR" ]; then
    echo "Warning: Project directory already exists. Some files may be overwritten."
  fi

  echo "Creating project directories..."
  # Create all required directories
  for dir in \
    "$PROJECT_DIR" \
    "$SUPPORT_DIR" \
    "$MAIN_DIR" \
    "$DJANGO_DIR" \
    "$SUPPORT_DIR/db_data" \
    "$SUPPORT_DIR/redis_data" \
    "$SUPPORT_DIR/.root" \
    "$SUPPORT_DIR/pgadmin" \
    "$SUPPORT_DIR/logs"; do
    if [ ! -d "$dir" ]; then
      mkdir -p "$dir"
    fi
  done

  # Create token file if it doesn't exist
  [ ! -f "$SUPPORT_DIR/token" ] && touch "$SUPPORT_DIR/token"

  # Set permissions for pgadmin directory
  chmod 777 "$SUPPORT_DIR/pgadmin"

  echo "Creating .gitignore..."
  cat >"$PROJECT_DIR/.gitignore" <<EOL
# Project specific
support/db_data/
support/redis_data/
support/pgadmin/
support/.root/
support/token
support/venv/
support/*.log
django_auth/static/

# Python
__pycache__/
*.py[cod]
*$py.class
*.so
.Python
build/
develop-eggs/
dist/
downloads/
eggs/
.eggs/
lib/
lib64/
parts/
sdist/
var/
wheels/
*.egg-info/
.installed.cfg
*.egg
MANIFEST

# Virtual Environment
venv/
ENV/
env/
.env

# IDE
.idea/
.vscode/
*.swp
*.swo
*~

# Logs
*.log
log/
logs/

# Database
*.sqlite3
*.db

# System Files
.DS_Store
Thumbs.db

# Alembic
versions/
EOL

  echo "Creating requirements.txt..."
  cat >"$REQUIREMENTS_FILE" <<EOL
fastapi
uvicorn
sqlmodel
pydantic[email]
psycopg2-binary
python-jose[cryptography]
passlib[bcrypt]
python-multipart
redis
fastapi-limiter
fastapi-cache2
python-dotenv
alembic
Pillow
PyYAML
django
djangorestframework
django-cors-headers
django-environ
djangorestframework-simplejwt
requests
gunicorn
EOL

  rev

  # Initialize Django project
  echo "Initializing Django project..."
  sleep 2
  podman run -it --rm -v "$PROJECT_DIR:/app:z" "$PYTHON_IMAGE" bash -c "
    source /app/support/venv/bin/activate && \
    cd /app/django_auth && \
    django-admin startproject auth_project . && \
    python manage.py startapp authentication"

  # Wait a moment to ensure files are created
  sleep 10

  # Create Django settings
  echo "Creating Django settings..."
  cat >"$DJANGO_DIR/auth_project/settings.py" <<EOL
import os
from pathlib import Path
from datetime import timedelta

BASE_DIR = Path(__file__).resolve().parent.parent

SECRET_KEY = 'django-insecure-change-this-in-production'

DEBUG = True

ALLOWED_HOSTS = ['*']

INSTALLED_APPS = [
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    'rest_framework',
    'corsheaders',
    'authentication',
]

MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'corsheaders.middleware.CorsMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]

ROOT_URLCONF = 'auth_project.urls'

TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.debug',
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]

WSGI_APPLICATION = 'auth_project.wsgi.application'

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': os.getenv('POSTGRES_DB'),
        'USER': os.getenv('POSTGRES_USER'),
        'PASSWORD': os.getenv('POSTGRES_PASSWORD'),
        'HOST': os.getenv('POSTGRES_CONTAINER_NAME'),
        'PORT': '5432',
    }
}

AUTH_PASSWORD_VALIDATORS = [
    {
        'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator',
    },
    {
        'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator',
    },
    {
        'NAME': 'django.contrib.auth.password_validation.CommonPasswordValidator',
    },
    {
        'NAME': 'django.contrib.auth.password_validation.NumericPasswordValidator',
    },
]

LANGUAGE_CODE = 'en-us'
TIME_ZONE = 'UTC'
USE_I18N = True
USE_TZ = True

STATIC_URL = 'static/'
STATIC_ROOT = os.path.join(BASE_DIR, 'static')

DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'

REST_FRAMEWORK = {
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'rest_framework_simplejwt.authentication.JWTAuthentication',
    ],
}

SIMPLE_JWT = {
    'AUTH_HEADER_TYPES': ('Bearer',),
    'ACCESS_TOKEN_LIFETIME': timedelta(minutes=60),
    'REFRESH_TOKEN_LIFETIME': timedelta(days=1),
}

CORS_ALLOW_ALL_ORIGINS = True
EOL

  echo "Creating Django authentication views..."
  cat >"$DJANGO_DIR/authentication/views.py" <<EOL
from rest_framework import status
from rest_framework.decorators import api_view, permission_classes
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated
from django.contrib.auth import authenticate
from rest_framework_simplejwt.tokens import RefreshToken

@api_view(['POST'])
def login(request):
    username = request.data.get('username')
    password = request.data.get('password')
    
    user = authenticate(username=username, password=password)
    if user:
        refresh = RefreshToken.for_user(user)
        return Response({
            'access': str(refresh.access_token),
            'refresh': str(refresh),
        })
    return Response({'error': 'Invalid credentials'}, status=status.HTTP_401_UNAUTHORIZED)

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def verify_token(request):
    return Response({'status': 'valid'})
EOL

  echo "Creating Django URLs..."
  cat >"$DJANGO_DIR/authentication/urls.py" <<EOL
from django.urls import path
from . import views

urlpatterns = [
    path('login/', views.login, name='login'),
    path('verify/', views.verify_token, name='verify'),
]
EOL

  echo "Creating Django project URLs..."
  cat >"$DJANGO_DIR/auth_project/urls.py" <<EOL
from django.contrib import admin
from django.urls import path, include

urlpatterns = [
    path('admin/', admin.site.urls),
    path('auth/', include('authentication.urls')),
]
EOL

  echo "Creating Django run script..."
  cat >"$DJANGO_DIR/run.sh" <<EOL
#!/bin/bash
source /app/support/venv/bin/activate
cd /app/django_auth

# Apply migrations
python manage.py makemigrations
python manage.py migrate

# Create superuser if it doesn't exist
python manage.py shell <<EOF
from django.contrib.auth import get_user_model
User = get_user_model()
if not User.objects.filter(username='admin').exists():
    User.objects.create_superuser('admin', 'admin@example.com', 'admin')
EOF

# Collect static files
python manage.py collectstatic --noinput

# Run with gunicorn
exec gunicorn auth_project.wsgi:application \
    --bind 0.0.0.0:8001 \
    --workers 2 \
    --threads 2 \
    --worker-class gthread \
    --worker-tmp-dir /dev/shm \
    --access-logfile /app/support/logs/gunicorn-access.log \
    --error-logfile /app/support/logs/gunicorn-error.log \
    --capture-output \
    --enable-stdio-inheritance \
    --reload
EOL

  chmod 755 "$DJANGO_DIR/run.sh"

  echo "Creating main.py..."
  cat >"$MAIN_FILE" <<EOL
from fastapi import FastAPI, HTTPException, Depends, Header
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi_cache import FastAPICache
from fastapi_cache.backends.redis import RedisBackend
from fastapi_limiter import FastAPILimiter
from redis import asyncio as aioredis
from sqlmodel import SQLModel
import sys, os, requests
sys.path.append('/app/main')
from db import engine
import uvicorn

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.on_event("startup")
async def startup():
    try:
        # Create database tables
        SQLModel.metadata.create_all(engine)
        
        # Initialize Redis using container name
        redis = aioredis.from_url(f"redis://{os.getenv('REDIS_CONTAINER_NAME', 'localhost')}:6379", encoding="utf8", decode_responses=True)
        await FastAPILimiter.init(redis)
        FastAPICache.init(RedisBackend(redis), prefix="fastapi-cache")
    except Exception as e:
        print(f"Startup error: {e}")
        raise

async def verify_token(authorization: str = Header(None)):
    if not authorization:
        raise HTTPException(status_code=401, detail="No token provided")
    
    try:
        response = requests.post(
            f"http://{os.getenv('DJANGO_CONTAINER_NAME')}:8001/auth/verify/",
            headers={"Authorization": authorization}
        )
        if response.status_code != 200:
            raise HTTPException(status_code=401, detail="Invalid token")
    except requests.RequestException:
        raise HTTPException(status_code=503, detail="Authentication service unavailable")

@app.get("/", dependencies=[Depends(verify_token)])
async def root():
    return {"message": "Hello World"}

if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
EOL

  echo "Creating db.py..."
  cat >"$DB_FILE" <<EOL
from sqlmodel import SQLModel, create_engine, Session
from typing import Generator
import os

# Use container name for database connection
POSTGRES_CONTAINER = os.getenv('POSTGRES_CONTAINER_NAME', 'localhost')
POSTGRES_USER = os.getenv('POSTGRES_USER', '${POSTGRES_USER}')
POSTGRES_PASSWORD = os.getenv('POSTGRES_PASSWORD', '${POSTGRES_PASSWORD}')
POSTGRES_DB = os.getenv('POSTGRES_DB', '${POSTGRES_DB}')

SQLALCHEMY_DATABASE_URL = f"postgresql://{POSTGRES_USER}:{POSTGRES_PASSWORD}@{POSTGRES_CONTAINER}:5432/{POSTGRES_DB}"

engine = create_engine(SQLALCHEMY_DATABASE_URL, pool_pre_ping=True)

def get_db() -> Generator[Session, None, None]:
    try:
        with Session(engine) as session:
            yield session
    except Exception as e:
        print(f"Database error: {e}")
        raise
EOL

  echo "Creating schemas.py..."
  cat >"$SCHEMAS_FILE" <<EOL
from sqlmodel import SQLModel, Field
from typing import Optional
from datetime import datetime

# Example model
class UserBase(SQLModel):
    email: str = Field(unique=True, index=True)
    username: str = Field(unique=True, index=True)
    full_name: str
    disabled: bool = False

class User(UserBase, table=True):
    id: Optional[int] = Field(default=None, primary_key=True)
    hashed_password: str
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: datetime = Field(default_factory=datetime.utcnow)

class UserCreate(UserBase):
    password: str

class UserRead(UserBase):
    id: int
    created_at: datetime
EOL

  echo "Creating uvicorn.sh..."
  cat >"$SUPPORT_DIR/uvicorn.sh" <<EOL
#!/bin/bash
source /app/support/venv/bin/activate
cd /app/main

# Run uvicorn with simplified logging
exec uvicorn main:app \
  --reload \
  --host 0.0.0.0 \
  --port 8000 \
  --workers 4 \
  --log-level debug \
  --access-log \
  --use-colors \
  --reload-dir /app/main \
  2>&1 | tee /app/support/logs/uvicorn.log
EOL

  chmod 755 "$SUPPORT_DIR/uvicorn.sh"

  echo "Creating nginx.conf..."
  cat >"$SUPPORT_DIR/nginx.conf" <<EOL
server {
    listen $PORT1;
    server_name 127.0.0.1;

    location /auth/ {
        proxy_pass http://127.0.0.1:8001/auth/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

  echo "Initializing Alembic..."
  podman run --rm -v "$PROJECT_DIR:/app:z" -w /app "$PYTHON_IMAGE" bash -c "
    source /app/support/venv/bin/activate && \
    cd /app/support && \
    pip install alembic && \
    alembic init migrations"
  sed -i "s|sqlalchemy.url = driver://user:pass@localhost/dbname|sqlalchemy.url = postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/${POSTGRES_DB}|g" "$SUPPORT_DIR/alembic.ini"
}

stop() {
  echo "Stopping and removing pod..."
  podman pod stop "$POD_NAME" || true
  podman pod rm "$POD_NAME" || true
}

run_postgres() {
  echo "Starting PostgreSQL container..."
  podman run -d --pod "$POD_NAME" --name "$POSTGRES_CONTAINER_NAME" \
    -e POSTGRES_DB="$POSTGRES_DB" \
    -e POSTGRES_USER="$POSTGRES_USER" \
    -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
    -v "$SUPPORT_DIR/db_data:/var/lib/postgresql/data:z" \
    "$POSTGRES_IMAGE"
}

run_redis() {
  echo "Starting Redis container..."
  podman run -d --pod "$POD_NAME" --name "$REDIS_CONTAINER_NAME" \
    -v "$SUPPORT_DIR/redis_data:/data:z" \
    "$REDIS_IMAGE" --loglevel warning
}

run_nginx() {
  echo "Starting Nginx container..."
  podman run -d --pod "$POD_NAME" --name "$NGINX_CONTAINER_NAME" \
    -v "$SUPPORT_DIR/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
    -v "$MAIN_DIR/staticfiles:/www/staticfiles:ro" \
    -v "$MAIN_DIR/media:/www/media:ro" \
    -v "$MAIN_DIR/frontend:/www/frontend:ro" \
    "$NGINX_IMAGE"
}

run_cfl_tunnel() {
  if [ ! -s "$SUPPORT_DIR/token" ]; then
    echo "Error: Cloudflare tunnel token is empty. Please add your token to $SUPPORT_DIR/token"
    return 1
  fi
  
  echo "Starting Cloudflare tunnel..."
  podman run -d --pod "$POD_NAME" --name "$CFL_TUNNEL_CONTAINER_NAME" \
    docker.io/cloudflare/cloudflared:latest tunnel --no-autoupdate run \
    --token $(cat "$SUPPORT_DIR/token")
}

run_uvicorn() {
  echo "Starting Uvicorn container..."
  podman run -d --pod "$POD_NAME" --name "$UVICORN_CONTAINER_NAME" \
    -v "$PROJECT_DIR:/app:z" \
    -v "$MAIN_DIR/media:/app/main/media:z" \
    -v "$SUPPORT_DIR/logs:/app/support/logs:z" \
    -e "POSTGRES_CONTAINER_NAME=$POSTGRES_CONTAINER_NAME" \
    -e "REDIS_CONTAINER_NAME=$REDIS_CONTAINER_NAME" \
    -e "DJANGO_CONTAINER_NAME=$DJANGO_CONTAINER_NAME" \
    -e "POSTGRES_USER=$POSTGRES_USER" \
    -e "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" \
    -e "POSTGRES_DB=$POSTGRES_DB" \
    -w /app \
    "$PYTHON_IMAGE" ./support/uvicorn.sh
}

run_interact() {
  echo "Starting interactive container..."
  podman run -d --pod "$POD_NAME" --name "$INTERACT_CONTAINER_NAME" \
    -v "$SUPPORT_DIR/.root:/root:z" \
    -v "$PROJECT_DIR:/app:z" \
    -w /app \
    "$PYTHON_IMAGE" bash -c "sleep infinity"
}

pg() {
  echo "Starting pgAdmin container..."
  podman run -d --rm --pod "$POD_NAME" --name "$PGADMIN_CONTAINER_NAME" \
    -e "PGADMIN_DEFAULT_EMAIL=dyka@brkh.work" \
    -e "PGADMIN_DEFAULT_PASSWORD=SuperSecret" \
    -e "PGADMIN_LISTEN_PORT=5050" \
    -v "$SUPPORT_DIR/pgadmin:/var/lib/pgadmin:z" \
    "$PGADMIN_IMAGE"
}

db() {
  echo "Running database migrations..."
  podman run -it --rm --pod "$POD_NAME" \
    -v "$PROJECT_DIR:/app:z" \
    -w /app/support \
    "$PYTHON_IMAGE" bash -c \
    "source /app/support/venv/bin/activate && alembic revision --autogenerate -m 'initial' && alembic upgrade head"
}

pod_create() {
  echo "Creating pod..."
  podman pod create --name "$POD_NAME" --network bridge
}

run_django() {
  echo "Starting Django container..."
  podman run -d --pod "$POD_NAME" --name "$DJANGO_CONTAINER_NAME" \
    -v "$PROJECT_DIR:/app:z" \
    -e "POSTGRES_CONTAINER_NAME=$POSTGRES_CONTAINER_NAME" \
    -e "POSTGRES_USER=$POSTGRES_USER" \
    -e "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" \
    -e "POSTGRES_DB=$POSTGRES_DB" \
    -w /app \
    "$PYTHON_IMAGE" ./django_auth/run.sh
}

esse() {
  run_postgres || return 1
  run_redis || return 1
  run_django || return 1
  run_uvicorn || return 1
  run_nginx || return 1
  run_cfl_tunnel || return 1
  run_interact || return 1
}

start() {
  pod_create
  esse
}

cek() {
  if podman pod exists "$POD_NAME"; then
    if [ "$(podman pod ps --filter name="$POD_NAME" --format "{{.Status}}" | awk '{print $1}')" = "Running" ]; then
      for container in "${POSTGRES_CONTAINER_NAME}" "${REDIS_CONTAINER_NAME}" "${DJANGO_CONTAINER_NAME}" "${UVICORN_CONTAINER_NAME}" "${NGINX_CONTAINER_NAME}" "${CFL_TUNNEL_CONTAINER_NAME}" "${INTERACT_CONTAINER_NAME}"; do
        if [ "$(podman ps --filter name="$container" --format "{{.Status}}" | awk '{print $1}')" != "Up" ]; then
          echo "Container $container is not running. Restarting..."
          podman start "$container" || {
            echo "Failed to restart $container"
            return 1
          }
        fi
      done
      echo "All containers are running."
    else
      echo "Pod is not running. Starting pod..."
      podman pod start "$POD_NAME" || {
        echo "Failed to start pod"
        return 1
      }
    fi
  else
    echo "Pod does not exist. Creating and starting..."
    start
  fi
}

# Execute the command
$1
