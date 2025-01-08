#!/bin/bash

# Source all required scripts
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/config/config.sh"
source "$SCRIPT_DIR/containers/container_ops.sh"
source "$SCRIPT_DIR/templates/base_templates.sh"
source "$SCRIPT_DIR/templates/django_templates.sh"
source "$SCRIPT_DIR/templates/fastapi_templates.sh"
source "$SCRIPT_DIR/init/project_init.sh"

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

# Set global variables
export APP_NAME="$1"
export COMMAND="$2"

# Define available commands
case "$COMMAND" in
    "init")
        check_podman
        initialize_project
        create_base_files
        create_django_files
        create_fastapi_files
        ;;
    "start")
        check_podman
        pod_create
        run_postgres
        wait_for_postgres
        run_redis
        run_django
        wait_for_django
        run_uvicorn
        run_nginx
        run_cfl_tunnel
        run_interact
        sleep 10
        run_migrations
        ;;
    "stop")
        pod_stop
        ;;
    "db")
        run_migrations
        ;;
    "pg")
        run_pgadmin
        ;;
    "cek")
        if podman pod exists "$POD_NAME"; then
            if [ "$(podman pod ps --filter name="$POD_NAME" --format "{{.Status}}" | awk '{print $1}')" = "Running" ]; then
                check_all_containers
            else
                echo "Pod is not running. Starting pod..."
                podman pod start "$POD_NAME" || {
                    echo "Failed to start pod"
                    exit 1
                }
            fi
        else
            echo "Pod does not exist. Creating and starting..."
            pod_create
            run_postgres
            wait_for_postgres
            run_redis
            run_django
            wait_for_django
            run_uvicorn
            run_nginx
            run_cfl_tunnel
            run_interact
            sleep 10
            run_migrations
        fi
        ;;
    *)
        echo "Error: Unknown command '$COMMAND'"
        echo "Available commands: init, start, stop, db, pg, cek"
        exit 1
        ;;
esac

exit 0