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
from schemas import Todo, TodoCreate, TodoRead  # We'll create these in a moment
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