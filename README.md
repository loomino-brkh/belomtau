# Belomtau

Welcome to the Belomtau project! This repository contains a collection of scripts and configurations for setting up and managing various development environments using Podman containers. This is a personal project and not intended for commercial use. The configurations and scripts reflect my personal preferences and setup.

## Table of Contents

- [Overview](#overview)
- [Scripts](#scripts)
  - [app.sh](#appsh)
  - [vue.sh](#vuesh)
  - [faster](#faster)
- [Usage](#usage)
- [License](#license)

## Overview

Belomtau is a set of scripts designed to automate the setup and management of development environments using Podman containers. The scripts cover a range of use cases, including setting up Django and FastAPI applications, as well as Vue.js front-end projects. The configurations are tailored to my personal preferences and are not intended for commercial or public use.

## Scripts

### app.sh

The `app.sh` script is designed to set up a Django-based API project. It includes configurations for PostgreSQL, Redis, Nginx, and Cloudflare Tunnel. The script automates the creation of a Django project, setting up the necessary directories, and configuring the environment.

#### Key Features:
- Initializes a Django project with essential dependencies.
- Sets up PostgreSQL and Redis containers.
- Configures Nginx as a reverse proxy.
- Integrates Cloudflare Tunnel for secure access.

### vue.sh

The `vue.sh` script is designed to set up a Vue.js front-end project using Vite. It includes configurations for Node.js and Nginx containers. The script automates the creation of a Vue.js project, setting up the necessary directories, and configuring the environment.

#### Key Features:
- Initializes a Vue.js project with essential dependencies.
- Sets up a Node.js container for development.
- Configures Nginx as a reverse proxy.

### faster

The `faster` script is a comprehensive setup for a full-stack application combining FastAPI and Django for authentication. It includes configurations for PostgreSQL, Redis, Uvicorn, Django, Nginx, and Cloudflare Tunnel. The script automates the creation of the project structure, setting up the necessary directories, and configuring the environment.

#### Key Features:
- Initializes a FastAPI project with essential dependencies.
- Sets up PostgreSQL and Redis containers.
- Configures Uvicorn for running FastAPI.
- Integrates Django for authentication.
- Configures Nginx as a reverse proxy.
- Integrates Cloudflare Tunnel for secure access.

## Usage

To use the scripts, follow these steps:

1. **Clone the Repository:**
   ```sh
   git clone https://github.com/yourusername/belomtau.git
   cd belomtau
   ```

2. **Run the Initialization Script:**
   For Django-based API project:
   ```sh
   ./app.sh init <app_name>
   ```

   For Vue.js front-end project:
   ```sh
   ./vue.sh init <app_name>
   ```

   For full-stack FastAPI and Django project:
   ```sh
   ./faster <app_name> init
   ```

3. **Start the Services:**
   ```sh
   ./app.sh start <app_name>
   ./vue.sh start <app_name>
   ./faster <app_name> start
   ```

4. **Check the Status:**
   ```sh
   ./app.sh cek <app_name>
   ./vue.sh cek <app_name>
   ./faster <app_name> cek
   ```

5. **Stop the Services:**
   ```sh
   ./app.sh stop <app_name>
   ./vue.sh stop <app_name>
   ./faster <app_name> stop
   ```

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for more details.

---

**Note:** This repository is a personal project and reflects my preferences and setup. It is not intended for commercial use or public distribution. Use at your own risk.
