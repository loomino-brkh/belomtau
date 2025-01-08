#!/bin/bash

source "$(dirname "$0")/../config/config.sh"

create_gitignore() {
  cat >"$PROJECT_DIR/.gitignore" <<EOL
# Project specific
support/db_data/
support/redis_data/
support/pgadmin/
support/token
support/venv/
support/*.log
django_auth/static/

# Python
__pycache__/
*.py[cod]
*\$py.class
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
}

create_requirements() {
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
django-redis
EOL
}

create_nginx_conf() {
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

    location /auth/static/ {
        alias /www/django_auth/staticfiles/;
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
}

create_uvicorn_script() {
  cat >"$SUPPORT_DIR/uvicorn.sh" <<EOL
#!/bin/bash
source /app/support/venv/bin/activate
cd /app/main

exec uvicorn main:app \\
  --reload \\
  --host 0.0.0.0 \\
  --port 8000 \\
  --workers 4 \\
  --log-level debug \\
  --access-log \\
  --use-colors \\
  --reload-dir /app/main
EOL

  chmod 755 "$SUPPORT_DIR/uvicorn.sh"
}

# Function to create all base files
create_base_files() {
  create_gitignore
  create_requirements
  create_nginx_conf
  create_uvicorn_script
}