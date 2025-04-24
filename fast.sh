#!/bin/bash
# --- faster (FastAPI Heavy Duty Setup) ---
# This script sets up a robust FastAPI application environment suitable for demanding workloads.
# Check if command argument is provided
if [ -z "$1" ]; then
    echo "Error: App name is required"
    echo "Usage: $0 <app_name> <command>"
    exit 1
fi

if [ -z "$2" ]; then
    echo "Error: Command is required"
    echo "Usage: $0 <app_name> <command>"
    exit 1
fi

APP_NAME="$1"
COMMAND="$2"

# Set up directory paths first
PROJECT_DIR="$HOME/projects/api_${APP_NAME}" # Main project directory
SUPPORT_DIR="${PROJECT_DIR}/support"
MAIN_DIR="${PROJECT_DIR}/main"
ROOT_DIR="$HOME/.root_dir" # Shared root directory (if needed)

# Container names
POD_NAME="${APP_NAME}_pod"
POSTGRES_CONTAINER_NAME="${APP_NAME}_postgres"
REDIS_CONTAINER_NAME="${APP_NAME}_redis"
UVICORN_CONTAINER_NAME="${APP_NAME}_uvicorn"
NGINX_CONTAINER_NAME="${APP_NAME}_nginx"
PGADMIN_CONTAINER_NAME="${APP_NAME}_pgadmin"
CFL_TUNNEL_CONTAINER_NAME="${APP_NAME}_cfltunnel"
INTERACT_CONTAINER_NAME="${APP_NAME}_interact"
# Add Celery worker/beat container names if using Celery
# CELERY_WORKER_CONTAINER_NAME="${APP_NAME}_celeryworker"
# CELERY_BEAT_CONTAINER_NAME="${APP_NAME}_celerybeat"
# FLOWER_CONTAINER_NAME="${APP_NAME}_flower"

# Load environment configuration
ENV_FILE="${SUPPORT_DIR}/env.conf"
if [ ! -f "$ENV_FILE" ]; then
    echo "Creating environment configuration..."
    mkdir -p "$SUPPORT_DIR"
    cat > "$ENV_FILE" <<EOL
# Application settings
HOST_DOMAIN="api.var.my.id" # Domain for Nginx/Cloudflare
PORT1="8080"  # Nginx external port
PORT2="8000"  # FastAPI internal port (Uvicorn listens here)
UVICORN_WORKERS=4 # Default number of Uvicorn workers (adjust based on CPU cores)

# Database settings (Adjust for heavy load)
DB_POOL_SIZE=20 # Increased default pool size
DB_MAX_OVERFLOW=40 # Increased default max overflow
DB_POOL_TIMEOUT=30 # Seconds to wait for connection from pool
DB_POOL_RECYCLE=1800 # Seconds after which connections are recycled (30 min)
DB_CONNECT_TIMEOUT=10 # Seconds to wait for establishing a new connection

# Image settings
POSTGRES_IMAGE="docker.io/library/postgres:16"
PYTHON_IMAGE="docker.io/library/python:latest" # Consider pinning to a specific version
REDIS_IMAGE="docker.io/library/redis:latest" # Consider pinning
NGINX_IMAGE="docker.io/library/nginx:latest" # Consider pinning
PGADMIN_IMAGE="docker.io/dpage/pgadmin4:latest"
CLOUDFLARED_IMAGE="docker.io/cloudflare/cloudflared:latest"
# CELERY_IMAGE="$PYTHON_IMAGE" # Use the same python image for celery

# Path settings
ROOT_DIR="$HOME/.root_dir"

# Security settings
ACCESS_TOKEN_EXPIRE_MINUTES=60 # Token expiry time in minutes
SECRET_KEY_LENGTH=64 # Length of generated secret keys
EOL
fi

# Generate secrets if not exists
if [ ! -f "${SUPPORT_DIR}/secrets.env" ]; then
    source "$ENV_FILE" # Source env to get SECRET_KEY_LENGTH
    pg_user="${APP_NAME}_user"
    # Generate strong, URL-safe passwords is better practice if used in URLs
    pg_pass=$(openssl rand -base64 32 | tr -d '/+' | head -c 40)
    pg_db="${APP_NAME}_db"
    fastapi_secret_key=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9=+/_\-' | head -c ${SECRET_KEY_LENGTH:-64})
    redis_pass=$(openssl rand -base64 32 | tr -d '/+' | head -c 40)
    # Add other secrets if needed (e.g., external API keys)
    # FIRST_SUPERUSER_PASSWORD=$(openssl rand -base64 16)

    cat > "${SUPPORT_DIR}/secrets.env" <<SECRETS
# Database credentials
POSTGRES_USER=$pg_user
POSTGRES_PASSWORD=$pg_pass
POSTGRES_DB=$pg_db

# FastAPI settings
SECRET_KEY=$fastapi_secret_key

# Redis settings
REDIS_PASSWORD=$redis_pass

# Optional: Initial superuser credentials (can be set manually or via API later)
# FIRST_SUPERUSER_EMAIL=admin@example.com
# FIRST_SUPERUSER_PASSWORD=$FIRST_SUPERUSER_PASSWORD

# Optional: Add other secrets here
# EXTERNAL_API_KEY=...
SECRETS
    chmod 600 "${SUPPORT_DIR}/secrets.env"
fi

# Source environment configuration
source "$ENV_FILE"

# Load secrets
set -a
source "${SUPPORT_DIR}/secrets.env"
set +a

# Cleanup function to unset environment variables
unset_secrets() {
    unset POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB SECRET_KEY REDIS_PASSWORD
    # Unset other secrets loaded from secrets.env
    # unset FIRST_SUPERUSER_PASSWORD EXTERNAL_API_KEY
}
trap unset_secrets EXIT

# Check if podman is installed
if ! command -v podman &> /dev/null; then
    echo "Error: podman is not installed"
    exit 1
fi

REQUIREMENTS_FILE="${SUPPORT_DIR}/requirements.txt"

rev() {
  echo "Creating Python virtual environment and installing requirements..."
  # Consider using a specific Python version image (e.g., python:3.11)
  # Ensure the base image has necessary build tools pre-installed if possible for faster builds
  podman run --rm -v "$PROJECT_DIR:/app:z" -v "$ROOT_DIR:/root:z" "$PYTHON_IMAGE" bash -c "
    apt-get update && \
    apt-get install -y curl build-essential pkg-config libssl-dev && \
    # Install Rust if needed by specific crypto libraries (e.g., newer cryptography)
    # Check if rust is strictly required by dependencies first
    if ! command -v cargo &> /dev/null; then
      echo 'Installing Rust...'
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
      . \"\$HOME/.cargo/env\"
    else
      echo 'Rust already installed.'
    fi && \
    python -m venv /app/support/venv && \
    source /app/support/venv/bin/activate && \
    pip install --upgrade pip setuptools wheel && \
    # Consider using pip-tools (pip-compile) for pinned dependencies
    pip install -r /app/support/requirements.txt" || { echo "Python environment setup failed."; exit 1; }
}

init() {
  # Check if project directory already exists
  if [ -d "$PROJECT_DIR" ]; then
    echo "Warning: Project directory '$PROJECT_DIR' already exists. Some files may be overwritten."
  fi

  echo "Creating project directories..."
  # Create all required directories
  for dir in \
    "$PROJECT_DIR" \
    "$SUPPORT_DIR" \
    "$MAIN_DIR" \
    "$MAIN_DIR/database" \
    "$MAIN_DIR/endpoints" \
    "$MAIN_DIR/core" \
    "$MAIN_DIR/models" \
    "$MAIN_DIR/schemas" \
    "$MAIN_DIR/services" \
    "$MAIN_DIR/utils" \
    "$MAIN_DIR/background_tasks" \
    "$ROOT_DIR" \
    "$SUPPORT_DIR/db_data" \
    "$SUPPORT_DIR/redis_data" \
    "$SUPPORT_DIR/pgadmin" \
    "$SUPPORT_DIR/logs" \
    "$SUPPORT_DIR/backups"; do # Added more structure
    if [ ! -d "$dir" ]; then
      mkdir -p "$dir"
    fi
  done

  # Create token file if it doesn't exist
  [ ! -f "$SUPPORT_DIR/token" ] && touch "$SUPPORT_DIR/token"

  # Set permissions for pgadmin directory
  chmod 777 "$SUPPORT_DIR/pgadmin" # Required by pgAdmin container

  echo "Creating .gitignore..."
  cat >"$PROJECT_DIR/.gitignore" <<EOL
# Project specific
support/db_data/
support/redis_data/
support/pgadmin/
support/token
support/venv/
support/logs/
support/*.log
support/secrets.env
support/backups/
support/env.conf # Might commit env.conf.example instead
support/alembic.ini # Store sensitive URL outside ini if possible

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
# Add compiled cython files if any
*.c
*.html # Cython reports

# Migrations (commit the migrations themselves)
# migrations/versions/

# Virtual Environment
venv/
ENV/
env/
.env* # Ignore all .env files
!/.env.example # Allow example env file

# IDE / Editor files
.idea/
.vscode/
*.swp
*.swo
*~
.project
.pydevproject
.settings/

# Logs
*.log
log/
logs/
*.log.*

# Database
*.sqlite3
*.db

# OS generated files
.DS_Store
Thumbs.db
Desktop.ini

# Test outputs
.coverage*
htmlcov/
*.prof
*.lprof
*.out

# Celery files
celerybeat-schedule

# Jupyter Notebook
.ipynb_checkpoints

# Build artifacts
*.tar.gz
*.zip
*.deb
*.rpm

# MyPy/Pyright cache
.mypy_cache/
.pytype/
.pyrightconfig.json # User specific settings
.ruff_cache/
EOL

  echo "Creating requirements.txt (heavy duty)..."
  cat >"$REQUIREMENTS_FILE" <<EOL
# --- Core FastAPI ---
fastapi
uvicorn[standard] # Includes standard dependencies like watchfiles for reload, websockets etc.
sqlmodel >= 0.0.14 # Pin to a recent version
pydantic[email] >= 2.0 # Ensure Pydantic v2
pydantic-settings # For loading settings

# --- Database ---
psycopg2-binary # Or psycopg if you prefer compiling
asyncpg # For async postgres access
alembic # Database migrations
SQLAlchemy-Utils # Useful utilities for SQLAlchemy/SQLModel

# --- Authentication & Security ---
python-jose[cryptography] # JWT handling
passlib[bcrypt] # Password hashing
bcrypt # Explicitly added for password hashing
python-multipart # For form data (like login/file uploads)
email-validator # Often needed with pydantic[email]

# --- Caching & Rate Limiting ---
redis >= 4.0 # Async redis client
fastapi-limiter # Request rate limiting
fastapi-cache2[redis] # Response caching

# --- Background Tasks (Heavy Duty Option) ---
celery[redis, SQS] # Include SQS if using AWS, etc.
flower # Celery monitoring web UI

# --- API Clients & HTTP ---
httpx # Modern async/sync HTTP client
requests # Standard sync HTTP client

# --- Utilities & Dev Tools ---
python-dotenv # Loading .env files
tenacity # Retrying operations (like DB connection)
PyYAML # Handling YAML config if needed
structlog # Advanced structured logging
# Consider rich for beautiful tracebacks/logging in dev

# --- Monitoring & Observability ---
prometheus-fastapi-instrumentator # Prometheus metrics exporter

# --- Optional Heavy-Duty Libraries (Uncomment as needed) ---
# Data Processing / ML
# pandas
# numpy
# scipy
# scikit-learn
# Joblib # For parallel processing / model persistence

# Image Processing
# Pillow

# Geospatial
# GeoAlchemy2
# Shapely

# Other specific needs
# beautifulsoup4 # Web scraping
# lxml # XML/HTML processing

# --- Consider for User Management (Alternative to custom auth) ---
# fastapi-users[sqlmodel,oauth,jwt] # Comprehensive user management library
EOL

  # Create basic FastAPI app structure
  echo "Creating core configuration files..."
  cat >"$MAIN_DIR/core/config.py" <<EOL
import os
from pydantic_settings import BaseSettings, SettingsConfigDict
from dotenv import load_dotenv
from pathlib import Path
from typing import List, Optional, Any # Use Any for complex structures if needed
from pydantic import PostgresDsn, RedisDsn, AnyHttpUrl, validator

# Load .env files from support directory. Secrets should override config.
support_dir = Path(__file__).resolve().parent.parent.parent / 'support'
env_path_conf = support_dir / 'env.conf'
env_path_secrets = support_dir / 'secrets.env'
load_dotenv(dotenv_path=env_path_conf)
load_dotenv(dotenv_path=env_path_secrets, override=True) # Secrets take precedence

class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file_encoding='utf-8', case_sensitive=True)

    PROJECT_NAME: str = os.getenv("APP_NAME", "${APP_NAME}")
    API_V1_STR: str = "/api/v1"
    APP_VERSION: str = "0.1.0" # Consider reading from pyproject.toml or similar

    # --- Security Settings ---
    SECRET_KEY: str # Must be loaded from secrets.env
    # Specify algorithm used for JWT
    ALGORITHM: str = "HS256"
    # Access token expire time in minutes (loaded from env.conf)
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 60

    # --- Database Settings ---
    POSTGRES_USER: str
    POSTGRES_PASSWORD: str
    POSTGRES_DB: str
    POSTGRES_CONTAINER_NAME: str = "localhost" # Default for local dev
    POSTGRES_PORT: str = "5432"

    # Derived database URLs using Pydantic validation
    # Note: DSN includes driver, user, password, host, port, db
    SYNC_DATABASE_URL: Optional[PostgresDsn] = None
    ASYNC_DATABASE_URL: Optional[PostgresDsn] = None

    @validator("SYNC_DATABASE_URL", pre=True, always=True)
    def assemble_sync_db_connection(cls, v: Optional[str], values: dict[str, Any]) -> Any:
        if isinstance(v, str):
            return v
        return PostgresDsn.build(
            scheme="postgresql",
            username=values.get("POSTGRES_USER"),
            password=values.get("POSTGRES_PASSWORD"),
            host=values.get("POSTGRES_CONTAINER_NAME"),
            port=int(values.get("POSTGRES_PORT", 5432)),
            path=f"{values.get('POSTGRES_DB') or ''}",
        )

    @validator("ASYNC_DATABASE_URL", pre=True, always=True)
    def assemble_async_db_connection(cls, v: Optional[str], values: dict[str, Any]) -> Any:
        if isinstance(v, str):
            return v
        return PostgresDsn.build(
            scheme="postgresql+asyncpg",
            username=values.get("POSTGRES_USER"),
            password=values.get("POSTGRES_PASSWORD"),
            host=values.get("POSTGRES_CONTAINER_NAME"),
            port=int(values.get("POSTGRES_PORT", 5432)),
            path=f"{values.get('POSTGRES_DB') or ''}",
        )

    # Database Pool Settings (loaded from env.conf)
    DB_POOL_SIZE: int = 10
    DB_MAX_OVERFLOW: int = 20
    DB_POOL_TIMEOUT: int = 30 # seconds
    DB_POOL_RECYCLE: int = 1800 # seconds (30 minutes)
    DB_CONNECT_TIMEOUT: int = 10 # seconds

    # --- Redis Settings ---
    REDIS_CONTAINER_NAME: str = "localhost" # Default for local dev
    REDIS_PASSWORD: Optional[str] = None
    REDIS_PORT: int = 6379
    REDIS_DB_CACHE: int = 0
    REDIS_DB_LIMITER: int = 1
    REDIS_DB_CELERY: int = 2

    # Derived Redis URLs
    REDIS_URL_CACHE: Optional[RedisDsn] = None
    REDIS_URL_LIMITER: Optional[RedisDsn] = None
    REDIS_URL_CELERY: Optional[RedisDsn] = None

    @validator("REDIS_URL_CACHE", pre=True, always=True)
    def assemble_redis_cache_url(cls, v: Optional[str], values: dict[str, Any]) -> Any:
        if isinstance(v, str): return v
        return RedisDsn.build(
            scheme="redis", host=values.get("REDIS_CONTAINER_NAME"), port=values.get("REDIS_PORT"),
            password=values.get("REDIS_PASSWORD"), path=f"/{values.get('REDIS_DB_CACHE')}"
        )

    @validator("REDIS_URL_LIMITER", pre=True, always=True)
    def assemble_redis_limiter_url(cls, v: Optional[str], values: dict[str, Any]) -> Any:
        if isinstance(v, str): return v
        return RedisDsn.build(
            scheme="redis", host=values.get("REDIS_CONTAINER_NAME"), port=values.get("REDIS_PORT"),
            password=values.get("REDIS_PASSWORD"), path=f"/{values.get('REDIS_DB_LIMITER')}"
        )

    @validator("REDIS_URL_CELERY", pre=True, always=True)
    def assemble_redis_celery_url(cls, v: Optional[str], values: dict[str, Any]) -> Any:
        if isinstance(v, str): return v
        return RedisDsn.build(
            scheme="redis", host=values.get("REDIS_CONTAINER_NAME"), port=values.get("REDIS_PORT"),
            password=values.get("REDIS_PASSWORD"), path=f"/{values.get('REDIS_DB_CELERY')}"
        )


    # --- CORS Settings ---
    # Should be a list of allowed origins, e.g., ["http://localhost:3000", "https://myapp.com"]
    # Use ["*"] for development only.
    BACKEND_CORS_ORIGINS: List[AnyHttpUrl] = ["*"]

    @validator("BACKEND_CORS_ORIGINS", pre=True)
    def assemble_cors_turn f"redis://{auth}{self.REDIS_CONTAINER_NAME}:{self.REDIS_PORT}/{self.REDIS_DB_CACHE}"

    @property
    def REDIS_URL_LIMITER(self) -> str:
        auth = f":{self.REDIS_PASSWORD}@" if self.REDIS_PASSWORD else ""
        return f"redis://{auth}{self.REDIS_CONTAINER_NAME}:{self.REDIS_PORT}/{self.REDIS_DB_LIMITER}"

    @property
    def REDIS_URL_CELERY(self) -> str:
        auth = f":{self.REDIS_PASSWORD}@" if self.REDIS_PASSWORD else ""
        return f"redis://{auth}{self.REDIS_CONTAINER_NAME}:{self.REDIS_PORT}/{self.REDIS_DB_CELERY}"

    # CORS settings
    BACKEND_CORS_ORIGINS: List[str] = ["*"] # Default to all, should be restricted in production

    # First user settings (optional)
    FIRST_SUPERUSER_EMAIL: str = os.getenv("FIRST_SUPERUSER_EMAIL", "admin@example.com")
    FIRST_SUPERUSER_PASSWORD: str = os.getenv("FIRST_SUPERUSER_PASSWORD", "changethis")

    class Config:
        case_sensitive = True
        # env_file = ".env" # Standard location, but we load manually above

settings = Settings()
EOL

  echo "Creating core/security.py..."
  cat >"$MAIN_DIR/core/security.py" <<EOL
from datetime import datetime, timedelta, timezone
from passlib.context import CryptContext
from jose import JWTError, jwt
from typing import Optional, Any
from pydantic import BaseModel, EmailStr

from core.config import settings

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

ALGORITHM = settings.ALGORITHM
SECRET_KEY = settings.SECRET_KEY
ACCESS_TOKEN_EXPIRE_MINUTES = settings.ACCESS_TOKEN_EXPIRE_MINUTES

class TokenPayload(BaseModel):
    sub: Optional[str] = None # 'sub' is standard for subject (user id or email)

def verify_password(plain_password: str, hashed_password: str) -> bool:
    return pwd_context.verify(plain_password, hashed_password)

def get_password_hash(password: str) -> str:
    return pwd_context.hash(password)

def create_access_token(subject: str | Any, expires_delta: Optional[timedelta] = None) -> str:
    if expires_delta:
        expire = datetime.now(timezone.utc) + expires_delta
    else:
        expire = datetime.now(timezone.utc) + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    to_encode = {"exp": expire, "sub": str(subject)}
    encoded_jwt = jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)
    return encoded_jwt

def decode_token(token: str) -> Optional[TokenPayload]:
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        token_data = TokenPayload(sub=payload.get("sub"))
        # Optional: Add expiration check here as well, though decode should handle it
        # if datetime.fromtimestamp(payload['exp'], tz=timezone.utc) < datetime.now(timezone.utc):
        #     return None # Token expired
        if token_data.sub is None:
             return None
        return token_data
    except JWTError:
        return None
EOL

  echo "Creating models/user.py..."
  cat >"$MAIN_DIR/models/user.py" <<EOL
from sqlmodel import SQLModel, Field, Relationship
from typing import Optional, List
from datetime import datetime
from pydantic import EmailStr

# Forward reference for relationship hints if needed, or import directly if possible
class Todo(SQLModel, table=False): pass

class UserBase(SQLModel):
    email: EmailStr = Field(unique=True, index=True, max_length=255)
    is_active: bool = Field(default=True)
    is_superuser: bool = Field(default=False)
    full_name: Optional[str] = Field(default=None, max_length=255)

class UserCreate(UserBase):
    password: str = Field(min_length=8)

class UserUpdate(SQLModel):
    email: Optional[EmailStr] = None
    password: Optional[str] = Field(default=None, min_length=8)
    full_name: Optional[str] = Field(default=None, max_length=255)
    is_active: Optional[bool] = None
    is_superuser: Optional[bool] = None


class User(UserBase, table=True):
    id: Optional[int] = Field(default=None, primary_key=True)
    hashed_password: str = Field(index=True) # Index might be useful depending on queries
    created_at: datetime = Field(default_factory=datetime.utcnow, nullable=False)
    updated_at: datetime = Field(default_factory=datetime.utcnow, nullable=False)

    # Example Relationship (adjust if needed)
    todos: List["Todo"] = Relationship(back_populates="owner")

# Schema for reading user data (excluding sensitive info)
class UserRead(UserBase):
    id: int
    created_at: datetime
    updated_at: datetime
EOL

  echo "Creating models/todo.py..."
  cat >"$MAIN_DIR/models/todo.py" <<EOL
from sqlmodel import SQLModel, Field, Relationship
from typing import Optional
from datetime import datetime
from models.user import User # Import User for relationship

class TodoBase(SQLModel):
    title: str = Field(..., min_length=1, index=True, max_length=255)
    description: Optional[str] = Field(default=None)
    completed: bool = Field(default=False)

class Todo(TodoBase, table=True):
    id: Optional[int] = Field(default=None, primary_key=True)
    created_at: datetime = Field(default_factory=datetime.utcnow, nullable=False)
    updated_at: datetime = Field(default_factory=datetime.utcnow, nullable=False)
    owner_id: int = Field(foreign_key="user.id", index=True, nullable=False) # Usually non-nullable

    # Relationship to User
    owner: User = Relationship(back_populates="todos") # Mark as non-optional if required

# Schema for creating Todos (owner_id will be set based on logged-in user)
class TodoCreate(TodoBase):
    pass

# Schema for reading Todos (includes ID and timestamps)
class TodoRead(TodoBase):
    id: int
    created_at: datetime
    updated_at: datetime
    owner_id: int

# Schema for reading Todos with nested owner info
class TodoReadWithOwner(TodoRead):
     owner: "UserRead" # Use the UserRead schema, avoid exposing password

# Schema for updating Todos (all fields optional)
class TodoUpdate(SQLModel):
    title: Optional[str] = Field(default=None, min_length=1, max_length=255)
    description: Optional[str] = None
    completed: Optional[bool] = None
EOL

  echo "Creating schemas/token.py..."
  cat >"$MAIN_DIR/schemas/token.py" <<EOL
from pydantic import BaseModel
from typing import Optional

class Token(BaseModel):
    access_token: str
    token_type: str = "bearer" # Usually fixed

class TokenPayload(BaseModel):
    sub: Optional[str] = None # 'sub' is standard for subject (user id or email)

# Optional: Add schema for password reset tokens if implementing that feature
# class PasswordResetTokenPayload(TokenPayload):
#     purpose: str = "password_reset"
EOL

  echo "Creating database/db.py..."
  cat >"$MAIN_DIR/database/db.py" <<EOL
from sqlmodel import SQLModel, create_engine, Session
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import QueuePool
from contextlib import contextmanager, asynccontextmanager
from typing import Generator, AsyncGenerator
import logging
from tenacity import retry, stop_after_attempt, wait_exponential, RetryError, wait_fixed

from core.config import settings

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Create engines with configurations from settings
sync_engine = create_engine(
    settings.SYNC_DATABASE_URL,
    poolclass=QueuePool,
    pool_size=settings.DB_POOL_SIZE,
    max_overflow=settings.DB_MAX_OVERFLOW,
    pool_timeout=settings.DB_POOL_TIMEOUT,
    pool_recycle=settings.DB_POOL_RECYCLE,
    pool_pre_ping=True,
    connect_args={
        "connect_timeout": settings.DB_CONNECT_TIMEOUT,
        "application_name": f"{settings.PROJECT_NAME}_sync"
    }
)

async_engine = create_async_engine(
    settings.ASYNC_DATABASE_URL,
    pool_size=settings.DB_POOL_SIZE,
    max_overflow=settings.DB_MAX_OVERFLOW,
    pool_timeout=settings.DB_POOL_TIMEOUT,
    pool_recycle=settings.DB_POOL_RECYCLE,
    pool_pre_ping=True,
    connect_args={
        # asyncpg uses 'timeout' for connection timeout
        "timeout": settings.DB_CONNECT_TIMEOUT,
        # Setting server settings can be useful for performance/debugging
        # "server_settings": {"application_name": f"{settings.PROJECT_NAME}_async"}
        "application_name": f"{settings.PROJECT_NAME}_async" # This seems supported now
    }
)

# Sessionmaker for async sessions
AsyncSessionLocal = sessionmaker(
    bind=async_engine, class_=AsyncSession, expire_on_commit=False
)

# Retry settings for session creation
RETRY_WAIT = wait_exponential(multiplier=1, min=2, max=6)
RETRY_STOP = stop_after_attempt(3)

@retry(wait=RETRY_WAIT, stop=RETRY_STOP, reraise=True)
def _create_sync_session() -> Session:
    try:
        # SQLModel's Session is a wrapper around SQLAlchemy's Session
        session = Session(sync_engine)
        logger.debug("Sync DB Session created")
        return session
    except Exception as e:
        logger.error(f"Failed to create sync database session: {e}")
        raise # Will be caught by retry

@contextmanager
def get_db() -> Generator[Session, None, None]:
    """ Provides a transactional scope around a series of sync operations. """
    db = _create_sync_session()
    try:
        yield db
        db.commit()
        logger.debug("Sync DB Session committed")
    except Exception as e:
        logger.error(f"Database session error: {e}", exc_info=True)
        db.rollback()
        logger.warning("Sync DB Session rolled back")
        raise
    finally:
        db.close()
        logger.debug("Sync DB Session closed")


@retry(wait=RETRY_WAIT, stop=RETRY_STOP, reraise=True)
async def _create_async_session() -> AsyncSession:
    try:
        session = AsyncSessionLocal()
        logger.debug("Async DB Session created")
        return session
    except Exception as e:
        logger.error(f"Failed to create async database session: {e}")
        raise # Will be caught by retry

@asynccontextmanager
async def get_async_db() -> AsyncGenerator[AsyncSession, None]:
    """ Provides a transactional scope around a series of async operations. """
    db = await _create_async_session()
    try:
        yield db
        await db.commit()
        logger.debug("Async DB Session committed")
    except Exception as e:
        logger.error(f"Async database session error: {e}", exc_info=True)
        await db.rollback()
        logger.warning("Async DB Session rolled back")
        raise
    finally:
        await db.close()
        logger.debug("Async DB Session closed")


# Retry settings for DB health check
CHECK_RETRY_WAIT = wait_fixed(2) # Wait 2 seconds between checks
CHECK_RETRY_STOP = stop_after_attempt(5) # Try 5 times

@retry(wait=CHECK_RETRY_WAIT, stop=CHECK_RETRY_STOP, reraise=True)
async def check_database_connection() -> bool:
    """ Check if database is responsive. """
    try:
        async with async_engine.connect() as conn:
            # Use a timeout for the connection attempt itself if supported by driver
            # For asyncpg, timeout is in connect_args
            await conn.execute("SELECT 1")
        logger.info("Database connection successful.")
        return True
    except Exception as e:
        logger.warning(f"Database connection check failed: {e}. Retrying...")
        raise RetryError(f"Database connection failed after multiple retries: {e}") from e

def init_db():
    """ Initialize database tables with error handling. """
    try:
        # Import all models here so SQLModel knows about them
        from models.user import User
        from models.todo import Todo
        logger.info("Creating database tables...")
        SQLModel.metadata.create_all(sync_engine)
        logger.info("Database tables created successfully (if they didn't exist).")
    except Exception as e:
        logger.error(f"Failed to create database tables: {e}", exc_info=True)
        raise
EOL

  echo "Creating database/crud.py..."
  cat >"$MAIN_DIR/database/crud.py" <<EOL
from sqlmodel import Session, select, SQLModel
from typing import Type, TypeVar, Generic, Optional, List

from models.user import User, UserCreate
from core.security import get_password_hash

ModelType = TypeVar("ModelType", bound=SQLModel)
CreateSchemaType = TypeVar("CreateSchemaType", bound=SQLModel)
UpdateSchemaType = TypeVar("UpdateSchemaType", bound=SQLModel)

class CRUDBase(Generic[ModelType, CreateSchemaType, UpdateSchemaType]):
    def __init__(self, model: Type[ModelType]):
        self.model = model

    def get(self, db: Session, id: int) -> Optional[ModelType]:
        return db.get(self.model, id)

    def get_multi(self, db: Session, *, skip: int = 0, limit: int = 100) -> List[ModelType]:
        statement = select(self.model).offset(skip).limit(limit)
        return db.exec(statement).all()

    def create(self, db: Session, *, obj_in: CreateSchemaType) -> ModelType:
        db_obj = self.model.model_validate(obj_in) # Pydantic v2 style
        db.add(db_obj)
        db.commit()
        db.refresh(db_obj)
        return db_obj

    def update(self, db: Session, *, db_obj: ModelType, obj_in: UpdateSchemaType | dict) -> ModelType:
        obj_data = db_obj.model_dump() # Pydantic v2 style
        if isinstance(obj_in, dict):
            update_data = obj_in
        else:
            update_data = obj_in.model_dump(exclude_unset=True) # Pydantic v2 style
        for field in obj_data:
            if field in update_data:
                setattr(db_obj, field, update_data[field])
        db.add(db_obj)
        db.commit()
        db.refresh(db_obj)
        return db_obj

    def remove(self, db: Session, *, id: int) -> Optional[ModelType]:
        obj = db.get(self.model, id)
        if obj:
            db.delete(obj)
            db.commit()
        return obj

class CRUDUser(CRUDBase[User, UserCreate, SQLModel]): # Update schema not defined yet
    def get_by_email(self, db: Session, *, email: str) -> Optional[User]:
        statement = select(User).where(User.email == email)
        return db.exec(statement).first()

    def create(self, db: Session, *, obj_in: UserCreate) -> User:
        hashed_password = get_password_hash(obj_in.password)
        # Create a dictionary excluding the plain password
        user_data = obj_in.model_dump(exclude={"password"})
        db_obj = User(**user_data, hashed_password=hashed_password)
        db.add(db_obj)
        db.commit()
        db.refresh(db_obj)
        return db_obj

    def is_superuser(self, user: User) -> bool:
        return user.is_superuser

user = CRUDUser(User)
EOL

  echo "Creating core/dependencies.py..."
  cat >"$MAIN_DIR/core/dependencies.py" <<EOL
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from sqlmodel import Session
from jose import JWTError

from core import security
from core.config import settings
from database import crud
from database.db import get_db
from models.user import User
from schemas.token import TokenPayload

oauth2_scheme = OAuth2PasswordBearer(tokenUrl=f"{settings.API_V1_STR}/auth/token")

def get_current_user(
    db: Session = Depends(get_db), token: str = Depends(oauth2_scheme)
) -> User:
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = security.jwt.decode(
            token, settings.SECRET_KEY, algorithms=[settings.ALGORITHM]
        )
        username: str | None = payload.get("sub")
        if username is None:
            raise credentials_exception
        token_data = TokenPayload(sub=username)
    except JWTError:
        raise credentials_exception

    user = crud.user.get_by_email(db, email=token_data.sub)
    if user is None:
        raise credentials_exception
    return user

def get_current_active_user(
    current_user: User = Depends(get_current_user),
) -> User:
    if not current_user.is_active:
        raise HTTPException(status_code=400, detail="Inactive user")
    return current_user

def get_current_active_superuser(
    current_user: User = Depends(get_current_active_user),
) -> User:
    if not crud.user.is_superuser(current_user):
        raise HTTPException(
            status_code=403, detail="The user doesn't have enough privileges"
        )
    return current_user
EOL

  echo "Creating endpoints/auth.py..."
  cat >"$MAIN_DIR/endpoints/auth.py" <<EOL
from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import OAuth2PasswordRequestForm
from sqlmodel import Session
from datetime import timedelta

from core import security
from core.config import settings
from core.dependencies import get_current_active_user
from database import crud
from database.db import get_db
from models.user import User, UserCreate, UserRead
from schemas.token import Token

router = APIRouter()

@router.post("/token", response_model=Token)
def login_for_access_token(
    db: Session = Depends(get_db), form_data: OAuth2PasswordRequestForm = Depends()
):
    """
    OAuth2 compatible token login, get an access token for future requests.
    """
    user = crud.user.get_by_email(db, email=form_data.username)
    if not user or not security.verify_password(form_data.password, user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect email or password",
            headers={"WWW-Authenticate": "Bearer"},
        )
    if not user.is_active:
        raise HTTPException(status_code=400, detail="Inactive user")

    access_token_expires = timedelta(minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES)
    access_token = security.create_access_token(
        data={"sub": user.email}, expires_delta=access_token_expires
    )
    return {"access_token": access_token, "token_type": "bearer"}

@router.post("/users/", response_model=UserRead, status_code=status.HTTP_201_CREATED)
def create_user(
    *,
    db: Session = Depends(get_db),
    user_in: UserCreate,
    # current_user: User = Depends(get_current_active_superuser) # Optional: Require admin to create users
):
    """
    Create new user. (Consider adding permissions).
    """
    user = crud.user.get_by_email(db, email=user_in.email)
    if user:
        raise HTTPException(
            status_code=400,
            detail="The user with this email already exists in the system.",
        )
    user = crud.user.create(db=db, obj_in=user_in)
    # TODO: Add logic to make the first user a superuser if needed
    # if crud.user.get_count(db) == 1: # Hypothetical count function
    #    crud.user.update(db, db_obj=user, obj_in={"is_superuser": True})
    return user

@router.get("/users/me", response_model=UserRead)
def read_users_me(
    current_user: User = Depends(get_current_active_user),
):
    """
    Get current user.
    """
    return current_user
EOL

  echo "Creating endpoints/todos.py..."
  cat >"$MAIN_DIR/endpoints/todos.py" <<EOL
from fastapi import APIRouter, HTTPException, Depends, Query
from sqlmodel import Session, select
from typing import List, Optional

from models.todo import Todo, TodoCreate, TodoRead, TodoUpdate
from models.user import User
from database.db import get_db
from core.dependencies import get_current_active_user

router = APIRouter()

@router.post("/", response_model=TodoRead, status_code=201)
def create_todo(
    *,
    db: Session = Depends(get_db),
    todo_in: TodoCreate,
    current_user: User = Depends(get_current_active_user)
):
    """
    Create a new todo item for the current user.
    """
    # Create Todo instance, linking it to the current user
    db_todo = Todo.model_validate(todo_in, update={"owner_id": current_user.id}) # Pydantic v2 style
    db.add(db_todo)
    db.commit()
    db.refresh(db_todo)
    return db_todo

@router.get("/", response_model=List[TodoRead])
def list_todos(
    db: Session = Depends(get_db),
    skip: int = 0,
    limit: int = Query(default=100, le=100),
    current_user: User = Depends(get_current_active_user)
):
    """
    Retrieve todo items for the current user.
    """
    statement = select(Todo).where(Todo.owner_id == current_user.id).offset(skip).limit(limit)
    todos = db.exec(statement).all()
    return todos

@router.get("/{todo_id}", response_model=TodoRead)
def get_todo(
    *,
    db: Session = Depends(get_db),
    todo_id: int,
    current_user: User = Depends(get_current_active_user)
):
    """
    Get a specific todo item by ID, ensuring it belongs to the current user.
    """
    statement = select(Todo).where(Todo.id == todo_id, Todo.owner_id == current_user.id)
    todo = db.exec(statement).first()
    if todo is None:
        raise HTTPException(status_code=404, detail="Todo not found or not owned by user")
    return todo

@router.put("/{todo_id}", response_model=TodoRead)
def update_todo(
    *,
    db: Session = Depends(get_db),
    todo_id: int,
    todo_in: TodoUpdate,
    current_user: User = Depends(get_current_active_user)
):
    """
    Update a todo item.
    """
    statement = select(Todo).where(Todo.id == todo_id, Todo.owner_id == current_user.id)
    db_todo = db.exec(statement).first()
    if not db_todo:
        raise HTTPException(status_code=404, detail="Todo not found or not owned by user")

    update_data = todo_in.model_dump(exclude_unset=True)
    for key, value in update_data.items():
        setattr(db_todo, key, value)

    db.add(db_todo)
    db.commit()
    db.refresh(db_todo)
    return db_todo

@router.delete("/{todo_id}", status_code=204)
def delete_todo(
    *,
    db: Session = Depends(get_db),
    todo_id: int,
    current_user: User = Depends(get_current_active_user)
):
    """
    Delete a todo item.
    """
    statement = select(Todo).where(Todo.id == todo_id, Todo.owner_id == current_user.id)
    todo = db.exec(statement).first()
    if not todo:
        raise HTTPException(status_code=404, detail="Todo not found or not owned by user")

    db.delete(todo)
    db.commit()
    # No response body for 204
EOL

  echo "Creating main.py..."
  cat >"$MAIN_DIR/main.py" <<EOL
from fastapi import FastAPI, Depends, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi_cache import FastAPICache
from fastapi_cache.backends.redis import RedisBackend
from fastapi_limiter import FastAPILimiter
from redis import asyncio as aioredis
from contextlib import asynccontextmanager
import logging

from core.config import settings
from database.db import init_db as initialize_database, check_database_connection
from endpoints import auth as auth_router
from endpoints import todos as todos_router

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    logger.info("Application startup...")
    try:
        logger.info("Checking database connection...")
        await check_database_connection() # Check DB before initializing cache/limiter
        logger.info("Database connection successful.")

        logger.info(f"Initializing Redis at {settings.REDIS_URL}...")
        redis = aioredis.from_url(settings.REDIS_URL, encoding="utf8", decode_responses=True)
        await FastAPILimiter.init(redis)
        FastAPICache.init(RedisBackend(redis), prefix="fastapi-cache")
        logger.info("Redis initialized for Limiter and Cache.")

        # Initialize database tables (run synchronously)
        # Consider running migrations via Alembic outside the app startup in production
        # initialize_database() # Creates tables if they don't exist

        logger.info("Startup complete.")
    except Exception as e:
        logger.error(f"Startup error: {e}", exc_info=True)
        # Depending on the error (e.g., DB down), you might want to exit or handle differently
        raise # Re-raise to prevent app from starting incorrectly

    yield
    # Shutdown
    logger.info("Application shutdown...")
    # Clean up resources if needed (e.g., close Redis connections explicitly if not handled by libraries)
    await FastAPICache.clear()
    logger.info("Shutdown complete.")


app = FastAPI(
    title=settings.PROJECT_NAME,
    openapi_url=f"{settings.API_V1_STR}/openapi.json",
    lifespan=lifespan
)

# CORS Middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], # Adjust in production!
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routers
app.include_router(auth_router.router, prefix=f"{settings.API_V1_STR}/auth", tags=["auth"])
app.include_router(todos_router.router, prefix=f"{settings.API_V1_STR}/todos", tags=["todos"])

@app.get("/")
async def root():
    return {"message": f"Welcome to {settings.PROJECT_NAME}"}

# Health check endpoint
@app.get("/health", status_code=200)
async def health_check():
    # Basic health check, can be expanded (e.g., check DB/Redis)
    return {"status": "ok"}

# Note: uvicorn run command should be outside this file, typically in a run script or Docker CMD
EOL

  # Create __init__.py files for Python packages
  touch "$MAIN_DIR/core/__init__.py"
  touch "$MAIN_DIR/database/__init__.py"
  touch "$MAIN_DIR/endpoints/__init__.py"
  touch "$MAIN_DIR/models/__init__.py"
  touch "$MAIN_DIR/schemas/__init__.py"

  # Create first version of requirements
  rev

  echo "Creating uvicorn.sh..."
  cat >"$SUPPORT_DIR/uvicorn.sh" <<EOL
#!/bin/bash
# Ensure secrets are available as env vars if needed directly by uvicorn/app startup outside of Python code
# Example: export SOME_VAR=\$(grep SOME_VAR /app/support/secrets.env | cut -d '=' -f2)

# Activate virtual environment
source /app/support/venv/bin/activate
cd /app/main

# Wait for DB? Optional, app startup logic should handle retries.
# echo "Waiting for DB..."
# sleep 10

# Run Alembic migrations before starting app
echo "Running database migrations..."
alembic -c /app/alembic.ini upgrade head
MIGRATION_STATUS=\$?
if [ \$MIGRATION_STATUS -ne 0 ]; then
  echo "Migration failed with status \$MIGRATION_STATUS. Exiting."
  exit \$MIGRATION_STATUS
fi
echo "Migrations applied."

# Run uvicorn
echo "Starting Uvicorn..."
exec uvicorn main:app \\
  --reload \\
  --host 0.0.0.0 \\
  --port ${PORT2} \\
  --workers 1 \\
  --log-level debug \\
  --access-log \\
  --use-colors \\
  --reload-dir /app/main
EOL

  chmod 755 "$SUPPORT_DIR/uvicorn.sh"

  echo "Creating nginx.conf..."
  cat >"$SUPPORT_DIR/nginx.conf" <<EOL
server {
    listen ${PORT1};
    server_name 127.0.0.1 localhost ${HOST_DOMAIN}; # Add HOST_DOMAIN if needed

    # Optional: Add security headers
    # add_header X-Frame-Options "SAMEORIGIN";
    # add_header X-Content-Type-Options "nosniff";
    # add_header Referrer-Policy "strict-origin-when-cross-origin";
    # add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # Increased buffer sizes for larger requests/responses if needed
    # proxy_buffers 8 16k;
    # proxy_buffer_size 32k;
    # client_max_body_size 10M; # Example: Allow 10MB uploads

    location / {
        proxy_pass http://127.0.0.1:${PORT2}; # Proxy to Uvicorn on the pod's internal network
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket support (if needed by FastAPI)
        # proxy_http_version 1.1;
        # proxy_set_header Upgrade \$http_upgrade;
        # proxy_set_header Connection "upgrade";
    }

    # Optional: Health check endpoint accessible directly
    location /nginx_health {
        access_log off;
        return 200 "Nginx is running";
        add_header Content-Type text/plain;
    }
}
EOL

  echo "Initializing Alembic..."
  # Ensure alembic is installed in the venv first
  podman run --rm -v "$PROJECT_DIR:/app:z" -w /app "$PYTHON_IMAGE" bash -c "
    source /app/support/venv/bin/activate && pip install alembic"

  # Initialize alembic
  podman run --rm -v "$PROJECT_DIR:/app:z" -w /app "$PYTHON_IMAGE" bash -c "
    source /app/support/venv/bin/activate && \
    alembic init -t async migrations" # Use async template

  # Rename alembic.ini to avoid conflict with project files
  mv "$PROJECT_DIR/alembic.ini" "$PROJECT_DIR/alembic.ini.template"
  # Create project specific alembic.ini
  cat >"$PROJECT_DIR/alembic.ini" <<EOL
[alembic]
script_location = migrations
file_template = %%(rev)s_%%(slug)s
# Define the database url using environment variables or direct values
# Make sure POSTGRES_USER, POSTGRES_PASSWORD, etc. are available in the environment where alembic runs
# Using secrets directly here is generally discouraged for security.
# Prefer sourcing secrets into the environment when running 'alembic' commands.
sqlalchemy.url = postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_CONTAINER_NAME}:${POSTGRES_PORT}/${POSTGRES_DB}

[loggers]
keys = root,sqlalchemy,alembic

[handlers]
keys = console

[formatters]
keys = generic

[logger_root]
level = WARN
handlers = console
qualname =

[logger_sqlalchemy]
level = WARN
handlers =
qualname = sqlalchemy.engine

[logger_alembic]
level = INFO
handlers =
qualname = alembic

[handler_console]
class = StreamHandler
args = (sys.stderr,)
level = NOTSET
formatter = generic

[formatter_generic]
format = %%(levelname)-5.5s [%%(name)s] %%(message)s
datefmt = %%H:%%M:%%S
EOL


  # Update migrations/env.py
  cat >"$PROJECT_DIR/migrations/env.py" <<EOT
import asyncio
from logging.config import fileConfig
import os
import sys
from pathlib import Path

from sqlalchemy import pool
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import async_engine_from_config

from alembic import context

# Add project root to Python path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

# Import SQLModel and models
from sqlmodel import SQLModel # noqa
# Ensure all models are imported here so Alembic detects them
from models.user import User # noqa
from models.todo import Todo # noqa

# Import settings to get database URL
from core.config import settings # noqa

# this is the Alembic Config object, which provides
# access to the values within the .ini file in use.
config = context.config

# Interpret the config file for Python logging.
# This line sets up loggers basically.
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

# Set the database URL from settings
# Make sure the environment variables used in core.config are set when running alembic
config.set_main_option("sqlalchemy.url", settings.ASYNC_DATABASE_URL)

# add your model's MetaData object here
# for 'autogenerate' support
# from myapp import mymodel
# target_metadata = mymodel.Base.metadata
target_metadata = SQLModel.metadata

# other values from the config, defined by the needs of env.py,
# can be acquired:
# my_important_option = config.get_main_option("my_important_option")
# ... etc.

def run_migrations_offline() -> None:
    """Run migrations in 'offline' mode.

    This configures the context with just a URL
    and not an Engine, though an Engine is acceptable
    here as well.  By skipping the Engine creation
    we don't even need a DBAPI to be available.

    Calls to context.execute() here emit the given string to the
    script output.

    """
    url = config.get_main_option("sqlalchemy.url")
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        render_as_batch=True, # For SQLite compatibility if needed, generally good practice
    )

    with context.begin_transaction():
        context.run_migrations()


def do_run_migrations(connection: Connection) -> None:
    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        render_as_batch=True, # For SQLite compatibility if needed, generally good practice
        compare_type=True,
        compare_server_default=True,
    )

    with context.begin_transaction():
        context.run_migrations()


async def run_migrations_online() -> None:
    """Run migrations in 'online' mode.

    In this scenario we need to create an Engine
    and associate a connection with the context.

    """
    connectable = async_engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )

    async with connectable.connect() as connection:
        await connection.run_sync(do_run_migrations)

    await connectable.dispose()


if context.is_offline_mode():
    run_migrations_offline()
else:
    asyncio.run(run_migrations_online())
EOT

  echo "Project initialization complete. Important files created:"
  echo "- FastAPI app: $MAIN_DIR/"
  echo "- Requirements: $REQUIREMENTS_FILE"
  echo "- Config: $ENV_FILE"
  echo "- Secrets: ${SUPPORT_DIR}/secrets.env (KEEP SAFE!)"
  echo "- Nginx config: $SUPPORT_DIR/nginx.conf"
  echo "- Uvicorn runner: $SUPPORT_DIR/uvicorn.sh"
  echo "- Alembic config: $PROJECT_DIR/alembic.ini"
  echo "- Migrations: $PROJECT_DIR/migrations/"
  echo "Next steps:"
  echo "1. Review configuration in $ENV_FILE and secrets in ${SUPPORT_DIR}/secrets.env"
  echo "2. Add Cloudflare token to $SUPPORT_DIR/token if using tunnel."
  echo "3. Run '$0 $APP_NAME start' to build and start services."
  echo "4. Create initial database schema/migrations: '$0 $APP_NAME db'"
  echo "5. Create the first user via API: POST to /api/v1/auth/users/ (e.g., using curl or Insomnia)"
  echo "   Example curl:"
  echo "   curl -X POST \"http://localhost:${PORT1}/api/v1/auth/users/\" \\"
  echo "        -H \"Content-Type: application/json\" \\"
  echo "        -d '{\"email\": \"admin@example.com\", \"password\": \"yourpassword\", \"full_name\": \"Admin User\"}'"
}

stop() {
  echo "Stopping and removing pod..."
  podman pod stop "$POD_NAME" || true
  podman pod rm "$POD_NAME" || true
  echo "Pod $POD_NAME stopped and removed."
}

run_postgres() {
  echo "Starting PostgreSQL container ($POSTGRES_CONTAINER_NAME)..."
  podman run -d --pod "$POD_NAME" --name "$POSTGRES_CONTAINER_NAME" \
    -e POSTGRES_DB="$POSTGRES_DB" \
    -e POSTGRES_USER="$POSTGRES_USER" \
    -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
    -v "$SUPPORT_DIR/db_data:/var/lib/postgresql/data:z" \
    --health-cmd='pg_isready -U $POSTGRES_USER -d $POSTGRES_DB' --health-interval=10s --health-timeout=5s --health-retries=5 \
    "$POSTGRES_IMAGE" || { echo "Failed to start PostgreSQL container"; return 1; }
}

wait_for_postgres() {
  echo "Waiting for PostgreSQL ($POSTGRES_CONTAINER_NAME) to be healthy..."
  for i in {1..30}; do
    # Use podman healthcheck state or pg_isready
    health_status=$(podman inspect --format '{{.State.Health.Status}}' "$POSTGRES_CONTAINER_NAME" 2>/dev/null)
    if [[ "$health_status" == "healthy" ]]; then
      echo "PostgreSQL is healthy."
      return 0
    elif podman exec "$POSTGRES_CONTAINER_NAME" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" &>/dev/null; then
       echo "PostgreSQL is ready (pg_isready)."
       # Give it a moment extra after pg_isready reports success before declaring fully healthy
       sleep 2
       return 0
    fi
    echo "Waiting for PostgreSQL... ($i/30) Status: $health_status"
    sleep 2
  done
  echo "PostgreSQL did not become ready/healthy in time."
  podman logs "$POSTGRES_CONTAINER_NAME"
  return 1
}

run_redis() {
  echo "Starting Redis container ($REDIS_CONTAINER_NAME)..."
  local redis_args="--loglevel warning"
  if [ -n "$REDIS_PASSWORD" ]; then
    redis_args="$redis_args --requirepass $REDIS_PASSWORD"
  fi
  podman run -d --pod "$POD_NAME" --name "$REDIS_CONTAINER_NAME" \
    -v "$SUPPORT_DIR/redis_data:/data:z" \
    --health-cmd='redis-cli ${REDIS_PASSWORD:+ -a $REDIS_PASSWORD} ping' --health-interval=10s --health-timeout=5s --health-retries=5 \
    "$REDIS_IMAGE" $redis_args || { echo "Failed to start Redis container"; return 1; }
  echo "Waiting for Redis to be healthy..."
  # Simple wait, can implement health check loop like postgres if needed
  sleep 5
}

run_nginx() {
  echo "Starting Nginx container ($NGINX_CONTAINER_NAME)..."
  podman run -d --pod "$POD_NAME" --name "$NGINX_CONTAINER_NAME" \
    -v "$SUPPORT_DIR/nginx.conf:/etc/nginx/conf.d/default.conf:ro,z" \
    --health-cmd='curl -f http://127.0.0.1:${PORT1}/nginx_health || exit 1' --health-interval=15s --health-timeout=5s --health-retries=3 \
    "$NGINX_IMAGE" || { echo "Failed to start Nginx container"; return 1; }
}

run_cfl_tunnel() {
  if [ ! -s "$SUPPORT_DIR/token" ]; then
    echo "Warning: Cloudflare tunnel token file ($SUPPORT_DIR/token) is empty or missing. Skipping tunnel."
    return 0 # Don't fail if token is missing
  fi

  echo "Starting Cloudflare tunnel ($CFL_TUNNEL_CONTAINER_NAME)..."
  podman run --network=host --dns 1.1.1.1 --dns 8.8.8.8 -d --pod "$POD_NAME" --name "$CFL_TUNNEL_CONTAINER_NAME" \
    --restart=always \
    "$CLOUDFLARED_IMAGE" tunnel --no-autoupdate run \
    --token $(cat "$SUPPORT_DIR/token") || { echo "Failed to start Cloudflare tunnel container"; return 1; }
}

run_uvicorn() {
  echo "Starting Uvicorn container ($UVICORN_CONTAINER_NAME)..."
  # Pass necessary environment variables from secrets/config
  podman run -d --pod "$POD_NAME" --name "$UVICORN_CONTAINER_NAME" \
    -v "$PROJECT_DIR:/app:z" \
    -v "$ROOT_DIR:/root:z" \
    -e "POSTGRES_CONTAINER_NAME=$POSTGRES_CONTAINER_NAME" \
    -e "REDIS_CONTAINER_NAME=$REDIS_CONTAINER_NAME" \
    -e "POSTGRES_USER=$POSTGRES_USER" \
    -e "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" \
    -e "POSTGRES_DB=$POSTGRES_DB" \
    -e "POSTGRES_PORT=5432" \
    -e "SECRET_KEY=$SECRET_KEY" \
    -e "ACCESS_TOKEN_EXPIRE_MINUTES=$ACCESS_TOKEN_EXPIRE_MINUTES" \
    -e "REDIS_PASSWORD=$REDIS_PASSWORD" \
    -w /app \
    "$PYTHON_IMAGE" ./support/uvicorn.sh || { echo "Failed to start Uvicorn container"; return 1; }
   # Optional: Add health check after uvicorn starts listening
}

run_interact() {
  echo "Starting interactive container ($INTERACT_CONTAINER_NAME)..."
  podman run -d --pod "$POD_NAME" --name "$INTERACT_CONTAINER_NAME" \
    -v "$ROOT_DIR:/root:z" \
    -v "$PROJECT_DIR:/app:z" \
    -e "POSTGRES_CONTAINER_NAME=$POSTGRES_CONTAINER_NAME" \
    -e "REDIS_CONTAINER_NAME=$REDIS_CONTAINER_NAME" \
    -e "POSTGRES_USER=$POSTGRES_USER" \
    -e "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" \
    -e "POSTGRES_DB=$POSTGRES_DB" \
    -e "POSTGRES_PORT=5432" \
    -e "SECRET_KEY=$SECRET_KEY" \
    -e "ACCESS_TOKEN_EXPIRE_MINUTES=$ACCESS_TOKEN_EXPIRE_MINUTES" \
    -e "REDIS_PASSWORD=$REDIS_PASSWORD" \
    -w /app \
    "$PYTHON_IMAGE" bash -c "source /app/support/venv/bin/activate && echo 'Interactive container ready. Type \"exit\" to stop.' && sleep infinity" || { echo "Failed to start interactive container"; return 1; }
}

run_cmd() {
  if ! podman container exists "$INTERACT_CONTAINER_NAME" || ! podman container inspect -f '{{.State.Running}}' "$INTERACT_CONTAINER_NAME" | grep -q true; then
     echo "Error: Interactive container '$INTERACT_CONTAINER_NAME' is not running. Start the services first."
     return 1
  fi
  echo "Executing in $INTERACT_CONTAINER_NAME: $*"
  # Execute command directly without intermediate bash -c unless necessary for complex commands
  podman exec -it "$INTERACT_CONTAINER_NAME" bash -c "source /app/support/venv/bin/activate && $*"
}

pg() {
  echo "Starting pgAdmin container ($PGADMIN_CONTAINER_NAME)..."
  # Expose pgAdmin port if not using default pod networking where it's accessible via localhost:mapping
  # For simplicity, assuming pod network access is sufficient. Add -p if needed.
  podman run -d --rm --pod "$POD_NAME" --name "$PGADMIN_CONTAINER_NAME" \
    -e "PGADMIN_DEFAULT_EMAIL=admin@example.com" \
    -e "PGADMIN_DEFAULT_PASSWORD=admin" \
    -e "PGADMIN_LISTEN_PORT=5050" \
    -v "$SUPPORT_DIR/pgadmin:/var/lib/pgadmin:z" \
    "$PGADMIN_IMAGE" || { echo "Failed to start pgAdmin container"; return 1; }
  echo "pgAdmin should be available within the pod network at http://${PGADMIN_CONTAINER_NAME}:5050"
  echo "If port mapping was added to pod create, access via host."
}

db() {
  echo "Running database migrations (Alembic)..."

  if ! podman container exists "$INTERACT_CONTAINER_NAME" || ! podman container inspect -f '{{.State.Running}}' "$INTERACT_CONTAINER_NAME" | grep -q true; then
     echo "Error: Interactive container '$INTERACT_CONTAINER_NAME' is not running. Start the services first."
     return 1
  fi

  if ! podman container exists "$POSTGRES_CONTAINER_NAME" || ! podman container inspect -f '{{.State.Running}}' "$POSTGRES_CONTAINER_NAME" | grep -q true; then
     echo "Error: PostgreSQL container '$POSTGRES_CONTAINER_NAME' is not running."
     return 1
  fi

  # Ensure Postgres is reachable from the interactive container
  echo "Checking PostgreSQL connection from interactive container..."
  if ! podman exec "$INTERACT_CONTAINER_NAME" bash -c "
        source /app/support/venv/bin/activate && \
        python -c \"import time, sys; from database.db import check_database_connection, RetryError; \
        try: asyncio.run(check_database_connection()) \
        except RetryError as e: print(f'DB connection failed: {e}'); sys.exit(1)\""; then
    echo "PostgreSQL connection failed from interactive container. Check logs."
    podman logs "$POSTGRES_CONTAINER_NAME"
    return 1
  fi
  echo "PostgreSQL connection successful."

  # Run Alembic migrations using run_cmd helper
  echo "Running Alembic migrations..."
  run_cmd "cd /app && alembic -c /app/alembic.ini revision --autogenerate -m 'auto_migration'" || {
    echo "Alembic revision generation failed."
    return 1
  }
  run_cmd "cd /app && alembic -c /app/alembic.ini upgrade head" || {
    echo "Alembic upgrade failed."
    return 1
  }

  echo "Database migrations completed successfully."
}


pod_create() {
  if podman pod exists "$POD_NAME"; then
    echo "Pod '$POD_NAME' already exists."
    return 0
  fi
  echo "Creating pod '$POD_NAME'..."
  # Map ports here if needed for external access without tunnel/nginx host mapping
  # Example: --publish ${PORT1}:${PORT1} --publish ${PORT2}:${PORT2}
  # Mapping PORT1 for Nginx is common. Mapping PORT2 might be needed for direct API access during dev.
  # Mapping 5050 for pgAdmin access from host.
  podman pod create --name "$POD_NAME" --network bridge -p ${PORT1}:${PORT1} -p 5050:5050 || {
    echo "Failed to create pod '$POD_NAME'."
    return 1
  }
  echo "Pod '$POD_NAME' created."
}

esse() {
  echo "Starting essential services..."
  run_postgres || return 1
  wait_for_postgres || return 1
  run_redis || return 1
  # Run migrations within uvicorn container start script
  run_uvicorn || return 1
  run_nginx || return 1
  run_cfl_tunnel # Don't fail if tunnel fails or is skipped
  run_interact || return 1
  echo "Essential services started."
}

start() {
  if podman pod exists "$POD_NAME"; then
     echo "Pod '$POD_NAME' exists. Checking status..."
     pod_status=$(podman pod inspect "$POD_NAME" --format "{{.State}}")
     if [[ "$pod_status" == "Running" ]]; then
        echo "Pod is already running. Use 'cek' to check container status or 'stop'/'restart'."
        return 0
     elif [[ "$pod_status" == "Exited" || "$pod_status" == "Stopped" ]]; then
        echo "Pod exists but is stopped. Starting pod..."
        podman pod start "$POD_NAME" || { echo "Failed to start existing pod."; return 1; }
        echo "Pod started. Checking services..."
        cek # Check and potentially start containers
        return 0
     elif [[ "$pod_status" == "Created" ]]; then
         echo "Pod exists but is only created. Starting services..."
         esse || return 1
         echo "Services started in existing created pod."
         return 0
     else
         echo "Pod exists in unknown state: $pod_status. Manual intervention may be required."
         echo "Attempting to remove and recreate..."
         stop || echo "Stop failed, continuing..." # Try to stop first
         pod_create || return 1
         esse || return 1
         sleep 5 # Give services time to stabilize
         return 0
     fi
  else
     echo "Pod '$POD_NAME' does not exist. Creating and starting..."
     pod_create || return 1
     esse || return 1
     sleep 5 # Give services time to stabilize
     echo "Application stack started successfully."
     echo "Access Nginx/API at http://localhost:${PORT1}"
     echo "Access pgAdmin at http://localhost:5050"
  fi
}

restart() {
    echo "Restarting application stack..."
    stop
    start
}

cek() {
  local all_running=true
  local pod_exists=false
  local pod_running=false

  if podman pod exists "$POD_NAME"; then
    pod_exists=true
    pod_status=$(podman pod inspect "$POD_NAME" --format "{{.State}}")
    if [[ "$pod_status" == "Running" ]]; then
      pod_running=true
    else
      echo "Pod '$POD_NAME' exists but is not running (State: $pod_status)."
      all_running=false
    fi
  else
    echo "Pod '$POD_NAME' does not exist."
    all_running=false
  fi

  if [[ "$pod_exists" == "false" ]]; then
     echo "Pod does not exist. Use 'start' to create and start."
     return 1
  fi

  if [[ "$pod_running" == "false" ]]; then
     echo "Attempting to start pod..."
     podman pod start "$POD_NAME" || { echo "Failed to start pod '$POD_NAME'"; return 1; }
     echo "Pod started, waiting briefly for containers..."
     sleep 5
  fi

  # List of essential containers
  containers=("${POSTGRES_CONTAINER_NAME}" "${REDIS_CONTAINER_NAME}" "${UVICORN_CONTAINER_NAME}" "${NGINX_CONTAINER_NAME}" "${INTERACT_CONTAINER_NAME}")
  # Add optional containers if they should be checked/restarted
  # containers+=("${CFL_TUNNEL_CONTAINER_NAME}" "${PGADMIN_CONTAINER_NAME}")

  echo "Checking container statuses..."
  for container in "${containers[@]}"; do
    if ! podman container exists "$container"; then
      echo "Container $container does not exist within the pod."
      all_running=false
      # Consider attempting to run the specific container start function here
      echo "Attempting to start missing container $container..."
      case "$container" in
          "$POSTGRES_CONTAINER_NAME") run_postgres && wait_for_postgres ;;
          "$REDIS_CONTAINER_NAME") run_redis ;;
          "$UVICORN_CONTAINER_NAME") run_uvicorn ;;
          "$NGINX_CONTAINER_NAME") run_nginx ;;
          "$INTERACT_CONTAINER_NAME") run_interact ;;
          # Add cases for optional containers if needed
          *) echo "Unknown container type: $container" ;;
      esac
      sleep 2 # Give it a moment
    else
      container_status=$(podman inspect --format '{{.State.Status}}' "$container" 2>/dev/null)
      if [[ "$container_status" == "running" ]]; then
        # Check health status if available
        health=$(podman inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' "$container" 2>/dev/null)
        if [[ "$health" == "unhealthy" ]]; then
           echo "Container $container is running but unhealthy."
           # Optionally attempt restart: podman restart "$container"
           all_running=false
        elif [[ "$health" == "starting" ]]; then
           echo "Container $container is starting..."
           all_running=false # Consider it not fully ready yet
        else
           echo "Container $container is running (Health: $health)."
        fi
      else
        echo "Container $container is not running (Status: $container_status)."
        all_running=false
        echo "Attempting to start container $container..."
        podman start "$container" || echo "Failed to start $container"
        sleep 2 # Give it a moment
      fi
    fi
  done

  if [[ "$all_running" == "true" ]]; then
    echo "All essential containers appear to be running."
    return 0
  else
    echo "Some containers are not running or unhealthy. Check logs for details."
    return 1
  fi
}

logs() {
    local container_name
    if [ -z "$3" ]; then
        echo "Error: Container name suffix is required (e.g., postgres, redis, uvicorn, nginx, interact)."
        echo "Usage: $0 $APP_NAME logs <container_suffix> [options]"
        return 1
    fi
    case "$3" in
        postgres) container_name="$POSTGRES_CONTAINER_NAME" ;;
        redis) container_name="$REDIS_CONTAINER_NAME" ;;
        uvicorn) container_name="$UVICORN_CONTAINER_NAME" ;;
        nginx) container_name="$NGINX_CONTAINER_NAME" ;;
        interact) container_name="$INTERACT_CONTAINER_NAME" ;;
        cfltunnel) container_name="$CFL_TUNNEL_CONTAINER_NAME" ;;
        pgadmin) container_name="$PGADMIN_CONTAINER_NAME" ;;
        *) echo "Error: Unknown container suffix '$3'"; return 1 ;;
    esac

    if ! podman container exists "$container_name"; then
        echo "Error: Container '$container_name' does not exist."
        return 1
    fi

    shift 3 # Remove app_name, logs command, and container_suffix
    echo "Showing logs for $container_name..."
    podman logs "$container_name" "$@" # Pass remaining args (like -f) to podman logs
}


# --- Main Command Execution ---

# Check if the command exists as a function
if declare -f "$COMMAND" > /dev/null; then
  # If command is run_cmd, pass all remaining arguments to it
  if [ "$COMMAND" = "run_cmd" ]; then
    shift 2 # Remove APP_NAME and COMMAND
    if [ -z "$1" ]; then
        echo "Error: Command to execute is required for run_cmd"
        echo "Usage: $0 <app_name> run_cmd <command_to_run>"
        exit 1
    fi
    run_cmd "$@"
  # If command is logs, handle its specific arguments
  elif [ "$COMMAND" = "logs" ]; then
      logs "$@" # Pass all args to logs function for parsing
  # Execute other known commands normally
  else
    $COMMAND
  fi
else
  echo "Error: Unknown command '$COMMAND'"
  echo "Available commands: init, start, stop, restart, db, pg, cek, logs, run_cmd"
  exit 1
fi

exit 0
