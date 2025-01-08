#!/bin/bash

source "$(dirname "$0")/../config/config.sh"

create_django_run_script() {
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
exec gunicorn auth_project.wsgi:application \\
    --bind 0.0.0.0:8001 \\
    --workers 2 \\
    --threads 2 \\
    --worker-class gthread \\
    --worker-tmp-dir /dev/shm \\
    --access-logfile /app/support/logs/gunicorn-access.log \\
    --error-logfile /app/support/logs/gunicorn-error.log \\
    --capture-output \\
    --enable-stdio-inheritance \\
    --reload
EOL

  chmod 755 "$DJANGO_DIR/run.sh"
}

create_django_views() {
  cat >"$DJANGO_DIR/authentication/views.py" <<EOL
from rest_framework import status
from rest_framework.decorators import api_view, permission_classes
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated
from django.contrib.auth import authenticate
from rest_framework_simplejwt.tokens import RefreshToken
from django.core.cache import cache
from django.views.decorators.cache import cache_page

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
    user_id = request.user.id
    cache_key = f'token_valid_{user_id}'

    cached_result = cache.get(cache_key)
    if cached_result is not None:
        return Response({'status': 'valid', 'cached': True})

    cache.set(cache_key, True, timeout=300)
    return Response({'status': 'valid', 'cached': False})

@api_view(['GET'])
@cache_page(60 * 15)
def cached_view(request):
    return Response({'message': 'This response is cached for 15 minutes'})
EOL
}

create_django_urls() {
  cat >"$DJANGO_DIR/auth_project/urls.py" <<EOL
from django.contrib import admin
from django.urls import path, include

urlpatterns = [
    path('admin/', admin.site.urls),
    path('auth/', include('authentication.urls')),
]
EOL

  cat >"$DJANGO_DIR/authentication/urls.py" <<EOL
from django.urls import path
from . import views

urlpatterns = [
    path('login/', views.login, name='login'),
    path('verify/', views.verify_token, name='verify'),
    path('cached/', views.cached_view, name='cached_view'),
]
EOL
}

create_django_settings() {
  cat >"$DJANGO_DIR/auth_project/settings.py" <<EOL
import os
from pathlib import Path
from datetime import timedelta

BASE_DIR = Path(__file__).resolve().parent.parent

SECRET_KEY = os.environ.get('DJANGO_SECRET_KEY', '${RANDOM_KEY}')

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

STATIC_URL = 'auth/static/'
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

CACHES = {
    "default": {
        "BACKEND": "django_redis.cache.RedisCache",
        "LOCATION": f"redis://{os.getenv('REDIS_CONTAINER_NAME', 'localhost')}:6379/1",
        "OPTIONS": {
            "CLIENT_CLASS": "django_redis.client.DefaultClient",
        }
    }
}

CORS_ALLOW_ALL_ORIGINS = True
EOL
}

# Function to create all Django files
create_django_files() {
  create_django_settings
  create_django_views
  create_django_urls
  create_django_run_script
}