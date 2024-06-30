#!/usr/bin/env bash

podman pod stop lomtau_pod
podman pod rm lomtau_pod
rm -rfv $HOME/django_lomtau