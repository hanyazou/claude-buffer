#!/bin/sh
# Build the claude-ubuntu image from the Dockerfile next to this script.
#
# The user inside the image gets the same UID/GID as the host user, so files
# created in the bind-mounted directories stay owned by you.
#
# Usage: ./build_image.sh [extra docker build options...]
#   IMAGE_NAME=my-image ./build_image.sh   # override the image name

set -eu

IMAGE_NAME=${IMAGE_NAME:-claude-ubuntu}

cd "$(dirname "$0")"

docker build \
    --build-arg USER_UID="$(id -u)" \
    --build-arg USER_GID="$(id -g)" \
    -t "$IMAGE_NAME" "$@" .
