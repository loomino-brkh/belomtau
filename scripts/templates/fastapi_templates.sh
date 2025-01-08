#!/bin/bash

source "$(dirname "$0")/../config/config.sh"

create_fastapi_main() {
  cat >"$MAIN_FILE" <<EOL
from fastapi import FastAPI, HTTPException, Depends, Header
from fastapi.middleware.cors import CORSMiddleware
from fastapi_cache import FastAPICache
from fastapi_cache.backends.redis import RedisBackend
from fastapi_limiter import FastAPILimiter
from redis import asyncio as aioredis
from sqlmodel import SQLModel, Session, select
import sys, os, requests
sys.path.append('/app/main')
from db import engine, get_db
from schemas import Todo, TodoCreate, TodoRead

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
        SQLModel.metadata.create_all(engine)
        redis = aioredis.from_url(
            f"redis://{os.getenv('REDIS_CONTAINER_NAME', 'localhost')}:6379",
            encoding="utf8",
            decode_responses=True
        )
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

@app.post("/todos/", response_model=TodoRead, dependencies=[Depends(verify_token)])
async def create_todo(todo: TodoCreate, db: Session = Depends(get_db)):
    db_todo = Todo.from_orm(todo)
    db.add(db_todo)
    db.commit()
    db.refresh(db_todo)
    return db_todo

@app.get("/todos/", response_model=list[TodoRead], dependencies=[Depends(verify_token)])
async def list_todos(db: Session = Depends(get_db)):
    todos = db.exec(select(Todo)).all()
    return todos

@app.get("/todos/{todo_id}", response_model=TodoRead, dependencies=[Depends(verify_token)])
async def get_todo(todo_id: int, db: Session = Depends(get_db)):
    todo = db.get(Todo, todo_id)
    if todo is None:
        raise HTTPException(status_code=404, detail="Todo not found")
    return todo

if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
EOL
}

create_fastapi_db() {
  cat >"$DB_FILE" <<EOL
from sqlmodel import SQLModel, create_engine, Session
from typing import Generator
import os

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
}

create_fastapi_schemas() {
  cat >"$SCHEMAS_FILE" <<EOL
from sqlmodel import SQLModel, Field
from typing import Optional
from datetime import datetime

class TodoBase(SQLModel):
    title: str = Field(..., min_length=1)
    description: Optional[str] = None
    completed: bool = False

class Todo(TodoBase, table=True):
    id: Optional[int] = Field(default=None, primary_key=True)
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: datetime = Field(default_factory=datetime.utcnow)

class TodoCreate(TodoBase):
    pass

class TodoRead(TodoBase):
    id: int
    created_at: datetime
    updated_at: datetime

class TodoUpdate(SQLModel):
    title: Optional[str] = None
    description: Optional[str] = None
    completed: Optional[bool] = None
EOL
}

create_alembic_env() {
  cat >"$SUPPORT_DIR/migrations/env.py" <<EOL
from logging.config import fileConfig
from sqlalchemy import engine_from_config
from sqlalchemy import pool
from alembic import context
import os, sys
from pathlib import Path

# Add the project directory to Python path
sys.path.append(str(Path(__file__).parents[2]))

# Import models
from main.schemas import *
from sqlmodel import SQLModel

# this is the Alembic Config object
config = context.config

# Interpret the config file for Python logging
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

# Set SQLModel metadata
target_metadata = SQLModel.metadata

def get_url():
    return f"postgresql://{os.getenv('POSTGRES_USER')}:{os.getenv('POSTGRES_PASSWORD')}@{os.getenv('POSTGRES_CONTAINER_NAME')}:5432/{os.getenv('POSTGRES_DB')}"

def run_migrations_offline() -> None:
    url = get_url()
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )

    with context.begin_transaction():
        context.run_migrations()

def run_migrations_online() -> None:
    configuration = config.get_section(config.config_ini_section)
    if configuration is not None:
        configuration["sqlalchemy.url"] = get_url()
    
    connectable = engine_from_config(
        configuration or {},
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )

    with connectable.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata
        )

        with context.begin_transaction():
            context.run_migrations()

if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
EOL
}

# Function to create all FastAPI files
create_fastapi_files() {
  create_fastapi_main
  create_fastapi_db
  create_fastapi_schemas
  create_alembic_env
}