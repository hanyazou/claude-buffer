#!/bin/sh
# Create and start the claude-ubuntu container from the image built by
# build_image.sh.
#
# The host directories are created first: if a bind-mount source is
# missing, docker creates it owned by root (on Linux).
#
# Usage: ./run_container.sh
#   IMAGE_NAME=my-image CLAUDE_CONTAINER_NAME=my-container ./run_container.sh

set -eu

IMAGE_NAME=${IMAGE_NAME:-claude-ubuntu}
CONTAINER_NAME=${CLAUDE_CONTAINER_NAME:-claude-ubuntu}

mkdir -p "$HOME/workspace"
mkdir -p "$HOME/claude-chats"
mkdir -p "$HOME/.claude/projects"

# Working directories are mounted at the same absolute path as on the host
# so that the paths claude records match what claude-buffer.el looks for.
docker run -dit \
    --name "$CONTAINER_NAME" \
    --hostname "$CONTAINER_NAME" \
    --init \
    -v "$HOME/workspace:$HOME/workspace" \
    -v "$HOME/claude-chats:$HOME/claude-chats" \
    -v "$HOME/.claude:/home/user/.claude" \
    "$IMAGE_NAME"
