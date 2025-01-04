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
UVICORN_CONTAINER_NAME="${APP_NAME}_uvicorn"
NGINX_CONTAINER_NAME="${APP_NAME}_nginx"
PGADMIN_CONTAINER_NAME="${APP_NAME}_pgadmin"
CFL_TUNNEL_CONTAINER_NAME="${APP_NAME}_cfltunnel"
INTERACT_CONTAINER_NAME="${APP_NAME}_interact"

REQUIREMENTS_FILE="${PROJECT_DIR}/requirements.txt"
MAIN_FILE="${PROJECT_DIR}/main.py"
DB_FILE="${PROJECT_DIR}/db.py"
SCHEMAS_FILE="${PROJECT_DIR}/schemas.py"

rev() {
  podman run --rm -v "$PROJECT_DIR:/app:z" "$PYTHON_IMAGE" python -m venv /app/venv
  podman run --rm -v "$PROJECT_DIR:/app:z" -w /app "$PYTHON_IMAGE" bash -c "source /app/venv/bin/activate && pip install --upgrade pip && pip install -r /app/requirements.txt"
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
  [ ! -d "$PROJECT_DIR/media" ] && mkdir -p "$PROJECT_DIR/media"

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
EOL

  rev

  cat >"$MAIN_FILE" <<EOL
from fastapi import FastAPI, HTTPException, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi_cache import FastAPICache
from fastapi_cache.backends.redis import RedisBackend
from fastapi_limiter import FastAPILimiter
from redis import asyncio as aioredis
from sqlmodel import SQLModel
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

app.mount("/static", StaticFiles(directory="staticfiles"), name="static")
app.mount("/media", StaticFiles(directory="media"), name="media")

@app.on_event("startup")
async def startup():
    # Create database tables
    SQLModel.metadata.create_all(engine)
    
    # Initialize Redis
    redis = aioredis.from_url("redis://localhost:6379", encoding="utf8", decode_responses=True)
    await FastAPILimiter.init(redis)
    FastAPICache.init(RedisBackend(redis), prefix="fastapi-cache")

@app.get("/")
async def root():
    return {"message": "Hello World"}

if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
EOL

  cat >"$DB_FILE" <<EOL
from sqlmodel import SQLModel, create_engine, Session
from typing import Generator

SQLALCHEMY_DATABASE_URL = f"postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/${POSTGRES_DB}"

engine = create_engine(SQLALCHEMY_DATABASE_URL)

def get_db() -> Generator[Session, None, None]:
    with Session(engine) as session:
        yield session
EOL

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

  cat >"$PROJECT_DIR/uvicorn.sh" <<EOL
#!/bin/bash
source /app/venv/bin/activate
cd /app
exec uvicorn main:app --reload --host 0.0.0.0 --port 8000
EOL

  chmod +x "$PROJECT_DIR/uvicorn.sh"

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

    location /api/ {
        proxy_pass http://127.0.0.1:8000/api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /static/ {
        alias /www/staticfiles/;
    }

    location /media/ {
        alias /www/media/;
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

  podman run --rm -v "$PROJECT_DIR:/app:z" -w /app "$PYTHON_IMAGE" bash -c "source /app/venv/bin/activate && alembic init migrations"
  sed -i "s|sqlalchemy.url = driver://user:pass@localhost/dbname|sqlalchemy.url = postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/${POSTGRES_DB}|g" "$PROJECT_DIR/alembic.ini"
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
    -v "$PROJECT_DIR/staticfiles:/www/staticfiles:ro" \
    -v "$PROJECT_DIR/media:/www/media:ro" \
    -v "$PROJECT_DIR/frontend:/www/frontend:ro" \
    "$NGINX_IMAGE"
}

run_cfl_tunnel() {
  podman run -d --pod "$POD_NAME" --name "$CFL_TUNNEL_CONTAINER_NAME" \
    docker.io/cloudflare/cloudflared:latest tunnel --no-autoupdate run \
    --token $(cat "$PROJECT_DIR/token")
}

run_uvicorn() {
  podman run -d --pod "$POD_NAME" --name "$UVICORN_CONTAINER_NAME" \
    -v "$PROJECT_DIR:/app:ro" \
    -v "$PROJECT_DIR/media:/app/media:z" \
    -w /app \
    "$PYTHON_IMAGE" bash -c "./uvicorn.sh"
}

run_interact() {
  podman run -d --pod "$POD_NAME" --name "$INTERACT_CONTAINER_NAME" \
    -v "$PROJECT_DIR:/app:z" \
    -w /app \
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

db() {
  podman run -it --rm --pod "$POD_NAME" \
    -v "$PROJECT_DIR:/app:z" \
    -w /app \
    "$PYTHON_IMAGE" bash -c \
    "source /app/venv/bin/activate && alembic revision --autogenerate -m 'initial' && alembic upgrade head"
}

pod_create() {
  podman pod create --name "$POD_NAME" --network bridge
}

esse() {
  run_postgres
  run_redis
  run_uvicorn
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
      for container in "${POSTGRES_CONTAINER_NAME}" "${REDIS_CONTAINER_NAME}" "${UVICORN_CONTAINER_NAME}" "${NGINX_CONTAINER_NAME}" "${CFL_TUNNEL_CONTAINER_NAME}" "${INTERACT_CONTAINER_NAME}"; do
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
