#!/bin/bash
# ---- Configuration -------
HOST_DOMAIN=""
PORT="8080"

APP_NAME="$1"
PROJECT_DIR="$HOME/projects/vue_ssr_${APP_NAME}"

NODE_IMAGE="docker.io/library/node:latest"
NGINX_IMAGE="docker.io/library/nginx:latest"

POD_NAME="${APP_NAME}_pod"
NODE_CONTAINER_NAME="${APP_NAME}_node"
NODE_DEV_CONTAINER_NAME="${APP_NAME}_node_dev"
NGINX_CONTAINER_NAME="${APP_NAME}_nginx"
CFL_TUNNEL_CONTAINER_NAME="${APP_NAME}_cfltunnel"

init() {
    [ ! -d "$PROJECT_DIR" ] && mkdir -p "$PROJECT_DIR"
    [ ! -f "$PROJECT_DIR/token" ] && touch "$PROJECT_DIR/token"

    # Create package.json if it doesn't exist
    if [ ! -f "$PROJECT_DIR/package.json" ]; then
        cat >"$PROJECT_DIR/package.json" <<'EOL'
{
  "name": "${APP_NAME}",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "node server",
    "serve": "NODE_ENV=production node server"
  },
  "dependencies": {
    "vue": "^3.3.4",
    "vue-router": "^4.2.4",
    "pinia": "^2.1.6",
    "axios": "^1.4.0",
    "express": "^4.18.2",
    "compression": "^1.7.4"
  },
  "devDependencies": {
    "@vitejs/plugin-vue": "^4.3.4",
    "vite": "^4.4.9",
    "sass": "^1.69.0"
  }
}
EOL
    fi

    # Create vite.config.js if it doesn't exist
    if [ ! -f "$PROJECT_DIR/vite.config.js" ]; then
        cat >"$PROJECT_DIR/vite.config.js" <<'EOL'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import { fileURLToPath, URL } from 'node:url'

export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url))
    }
  },
  server: {
    host: '0.0.0.0',
    port: 8090
  },
  css: {
    preprocessorOptions: {
      scss: {
        additionalData: '@import "@/assets/styles/variables.scss";'
      }
    }
  }
})
EOL
    fi

    # Create server.js if it doesn't exist
    if [ ! -f "$PROJECT_DIR/server.js" ]; then
        cat >"$PROJECT_DIR/server.js" <<'EOL'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import express from 'express'
import compression from 'compression'
import { createServer as createViteServer } from 'vite'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const isProduction = process.env.NODE_ENV === 'production'
const PORT = 8090

async function createServer() {
  const app = express()
  app.use(compression())

  let vite
  if (!isProduction) {
    // Development mode
    vite = await createViteServer({
      server: { middlewareMode: true },
      appType: 'custom'
    })
    app.use(vite.middlewares)
  } else {
    // Production mode - serve static assets but still use SSR for HTML
    app.use(express.static(path.resolve(__dirname, 'public')))
  }

  app.use('*', async (req, res) => {
    const url = req.originalUrl

    try {
      let template, render

      if (!isProduction) {
        // Development mode
        template = fs.readFileSync(path.resolve(__dirname, 'index.html'), 'utf-8')
        template = await vite.transformIndexHtml(url, template)

        // Load the server entry module
        const { render: ssrRender } = await vite.ssrLoadModule('/src/entry-server.js')
        render = ssrRender
      } else {
        // Production mode - always use SSR even in production
        template = fs.readFileSync(path.resolve(__dirname, 'index.html'), 'utf-8')
        const { render: ssrRender } = await import('./src/entry-server.js')
        render = ssrRender
      }

      // Render the app HTML
      const { appHtml, preloadLinks, headTags, htmlAttrs, bodyAttrs } = await render(url)

      // Inject the app HTML into the template
      const html = template
        .replace('<html>', `<html ${htmlAttrs}>`)
        .replace('<body>', `<body ${bodyAttrs}>`)
        .replace('<!--preload-links-->', preloadLinks)
        .replace('<!--head-tags-->', headTags)
        .replace('<!--app-html-->', appHtml)

      res.status(200).set({ 'Content-Type': 'text/html' }).end(html)
    } catch (e) {
      if (!isProduction) {
        vite.ssrFixStacktrace(e)
      }
      console.log(e.stack)
      res.status(500).end(e.stack)
    }
  })

  app.listen(PORT, () => {
    console.log(`Server is running on http://localhost:${PORT}`)
  })
}

createServer()
EOL
    fi

    # Create src/entry-server.js if it doesn't exist
    if [ ! -d "$PROJECT_DIR/src" ]; then
        mkdir -p "$PROJECT_DIR/src"
    fi

    if [ ! -f "$PROJECT_DIR/src/entry-server.js" ]; then
        cat >"$PROJECT_DIR/src/entry-server.js" <<'EOL'
import { createApp } from './main'
import { renderToString } from 'vue/server-renderer'

export async function render(url) {
  const { app, router, head } = createApp()

  // Set the server-side router location
  await router.push(url)
  await router.isReady()

  // Render the app as a string
  const appHtml = await renderToString(app)

  // Get head tags, html and body attributes
  const headTags = head ? head.renderHeadToString() : ''
  const htmlAttrs = head ? head.renderHtmlAttrs() : ''
  const bodyAttrs = head ? head.renderBodyAttrs() : ''

  return {
    appHtml,
    preloadLinks: '',
    headTags,
    htmlAttrs,
    bodyAttrs
  }
}
EOL
    fi

    # Create src/entry-client.js if it doesn't exist
    if [ ! -f "$PROJECT_DIR/src/entry-client.js" ]; then
        cat >"$PROJECT_DIR/src/entry-client.js" <<'EOL'
import { createApp } from './main'
import './assets/styles/main.scss'

const { app, router } = createApp()

// Wait for the router to be ready before mounting the app
router.isReady().then(() => {
  app.mount('#app')
})
EOL
    fi

    # Create src/main.js if it doesn't exist
    if [ ! -f "$PROJECT_DIR/src/main.js" ]; then
        cat >"$PROJECT_DIR/src/main.js" <<'EOL'
import { createSSRApp } from 'vue'
import { createRouter } from './router'
import { createPinia } from 'pinia'
import App from './App.vue'

// Export a function that creates and configures the app
export function createApp() {
  const app = createSSRApp(App)
  const router = createRouter()
  const pinia = createPinia()

  app.use(router)
  app.use(pinia)

  return { app, router }
}
EOL
    fi

    # Create src/router.js if it doesn't exist
    if [ ! -f "$PROJECT_DIR/src/router.js" ]; then
        cat >"$PROJECT_DIR/src/router.js" <<'EOL'
import { createRouter as _createRouter, createMemoryHistory, createWebHistory } from 'vue-router'

// Routes definition
const routes = [
  {
    path: '/',
    name: 'Home',
    component: () => import('./pages/Home.vue')
  }
]

export function createRouter() {
  return _createRouter({
    // Use memory history for SSR, otherwise use browser history
    history: import.meta.env.SSR ? createMemoryHistory() : createWebHistory(),
    routes
  })
}
EOL
    fi

    # Create index.html if it doesn't exist
    if [ ! -f "$PROJECT_DIR/index.html" ]; then
        cat >"$PROJECT_DIR/index.html" <<'EOL'
<!DOCTYPE html>
<html>
  <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${APP_NAME}</title>
    <!--head-tags-->
    <!--preload-links-->
  </head>
  <body>
    <div id="app"><!--app-html--></div>
    <script type="module" src="/src/entry-client.js"></script>
  </body>
</html>
EOL
    fi

    # Create SCSS directories and files
    if [ ! -d "$PROJECT_DIR/src/assets/styles" ]; then
        mkdir -p "$PROJECT_DIR/src/assets/styles"
    fi

    # Create variables.scss if it doesn't exist
    if [ ! -f "$PROJECT_DIR/src/assets/styles/variables.scss" ]; then
        cat >"$PROJECT_DIR/src/assets/styles/variables.scss" <<'EOL'
// Colors
$primary-color: #3498db;
$secondary-color: #2ecc71;
$text-color: #333;
$background-color: #fff;

// Breakpoints
$mobile: 768px;
$tablet: 992px;
$desktop: 1200px;

// Typography
$font-family: 'Arial', sans-serif;
$base-font-size: 16px;
$heading-font-size: 24px;
EOL
    fi

    # Create main.scss if it doesn't exist
    if [ ! -f "$PROJECT_DIR/src/assets/styles/main.scss" ]; then
        cat >"$PROJECT_DIR/src/assets/styles/main.scss" <<'EOL'
@import 'variables';

// Global styles
body {
  font-family: $font-family;
  font-size: $base-font-size;
  color: $text-color;
  background-color: $background-color;
  margin: 0;
  padding: 0;
  box-sizing: border-box;
}

h1, h2, h3, h4, h5, h6 {
  font-weight: bold;
}

a {
  color: $primary-color;
  text-decoration: none;

  &:hover {
    text-decoration: underline;
  }
}

.container {
  max-width: 1200px;
  margin: 0 auto;
  padding: 0 15px;
}
EOL
    fi

    # Create pages directory and Home.vue component if they don't exist
    if [ ! -d "$PROJECT_DIR/src/pages" ]; then
        mkdir -p "$PROJECT_DIR/src/pages"
    fi

    if [ ! -f "$PROJECT_DIR/src/pages/Home.vue" ]; then
        cat >"$PROJECT_DIR/src/pages/Home.vue" <<'EOL'
<template>
  <div class="home">
    <h1>Welcome to ${APP_NAME}</h1>
    <p>This is a Vue SSR app with Vite and SCSS</p>
  </div>
</template>

<style lang="scss">
.home {
  text-align: center;
  padding: 2rem;

  h1 {
    color: $primary-color;
    font-size: $heading-font-size;
    margin-bottom: 1rem;
  }

  p {
    color: $text-color;
    max-width: 600px;
    margin: 0 auto;
  }
}
</style>
EOL
    fi

    # Create App.vue if it doesn't exist
    if [ ! -f "$PROJECT_DIR/src/App.vue" ]; then
        cat >"$PROJECT_DIR/src/App.vue" <<'EOL'
<template>
  <div class="app">
    <router-view></router-view>
  </div>
</template>

<style lang="scss">
.app {
  width: 100%;
  min-height: 100vh;
}
</style>
EOL
    fi

    # Create nginx.conf if it doesn't exist
    if [ ! -f "$PROJECT_DIR/nginx.conf" ]; then
        cat >"$PROJECT_DIR/nginx.conf" <<EOL
server {
    listen ${PORT};
    server_name localhost;

    location / {
        proxy_pass http://127.0.0.1:8090;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOL
    fi

    # Create public directory if it doesn't exist
    if [ ! -d "$PROJECT_DIR/public" ]; then
        mkdir -p "$PROJECT_DIR/public"
    fi
}

stop() {
    podman pod stop "$POD_NAME"
    podman pod rm "$POD_NAME"
}

run_node() {
    podman run -d --pod "$POD_NAME" --name "$NODE_CONTAINER_NAME" \
        -v "$PROJECT_DIR:/app:z" \
        -w /app \
        -e NODE_ENV=production \
        "$NODE_IMAGE" sh -c "npm install && npm run serve"
}

run_nginx() {
    podman run -d --pod "$POD_NAME" --name "$NGINX_CONTAINER_NAME" \
        -v "$PROJECT_DIR/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
        -e PORT="$PORT" \
        "$NGINX_IMAGE"
}

run_cfl_tunnel() {
    podman run -d --pod "$POD_NAME" --name "$CFL_TUNNEL_CONTAINER_NAME" \
        docker.io/cloudflare/cloudflared:latest tunnel --no-autoupdate run \
        --token $(cat "$PROJECT_DIR/token")
}

pod_create() {
    podman pod create --name "$POD_NAME" --network bridge
}

start() {
    # Check if dev environment is running
    if podman pod exists "$POD_NAME" && podman container exists "$NODE_DEV_CONTAINER_NAME"; then
        echo "Development environment is already running. Please stop it first with 'stop' command."
        return 1
    fi

    pod_create
    run_node
    run_nginx
    run_cfl_tunnel
}

start_dev() {
    # Check if production environment is running
    if podman pod exists "$POD_NAME" && podman container exists "$NODE_CONTAINER_NAME"; then
        echo "Production environment is already running. Please stop it first with 'stop' command."
        return 1
    fi

    pod_create
    podman run -d --pod "$POD_NAME" --name "$NODE_DEV_CONTAINER_NAME" \
        -v "$PROJECT_DIR:/app:z" \
        -w /app \
        "$NODE_IMAGE" sh -c "npm install && npm run dev"
    run_nginx
    run_cfl_tunnel
}

cek() {
    if podman pod exists "$POD_NAME"; then
        if [ "$(podman pod ps --filter name="$POD_NAME" --format "{{.Status}}" | awk '{print $1}')" = "Running" ]; then
            # Check if production or development environment is running
            if podman container exists "$NODE_CONTAINER_NAME"; then
                echo "Production environment is running."
                # Check if all containers are running
                for container in "${NODE_CONTAINER_NAME}" "${NGINX_CONTAINER_NAME}" "${CFL_TUNNEL_CONTAINER_NAME}"; do
                    if [ "$(podman ps --filter name="$container" --format "{{.Status}}" | awk '{print $1}')" != "Up" ]; then
                        echo "Container $container is not running. Restarting..."
                        podman start "$container"
                    fi
                done
            elif podman container exists "$NODE_DEV_CONTAINER_NAME"; then
                echo "Development environment is running."
                # Check if all dev containers are running
                for container in "${NODE_DEV_CONTAINER_NAME}" "${NGINX_CONTAINER_NAME}" "${CFL_TUNNEL_CONTAINER_NAME}"; do
                    if [ "$(podman ps --filter name="$container" --format "{{.Status}}" | awk '{print $1}')" != "Up" ]; then
                        echo "Container $container is not running. Restarting..."
                        podman start "$container"
                    fi
                done
            else
                echo "Pod exists but neither production nor development environment is properly configured."
                echo "Stopping pod and starting production environment..."
                stop
                start
            fi
        else
            echo "Pod exists but is not running. Starting pod..."
            podman pod start "$POD_NAME"

            # Check which environment was running previously
            if podman container exists "$NODE_CONTAINER_NAME"; then
                echo "Resuming production environment."
            elif podman container exists "$NODE_DEV_CONTAINER_NAME"; then
                echo "Resuming development environment."
            else
                echo "Neither production nor development environment is properly configured."
            fi
        fi
    else
        echo "No environment is running. Starting production environment..."
        start
    fi
}

$2
