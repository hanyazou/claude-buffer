#!/bin/sh
# Sample wrapper that runs the Claude Code CLI inside the claude-ubuntu
# container. Copy it to a directory on your PATH as `claude', e.g.:
#
#   cp claude-wrapper.sh ~/bin/claude && chmod +x ~/bin/claude
#
# The host's current directory is passed through with -w, so it must be
# inside one of the directories bind-mounted at the same absolute path
# (see README.md); otherwise docker exec fails.

CONTAINER_NAME=${CLAUDE_CONTAINER_NAME:-claude-ubuntu}

exec docker exec -i -w "$PWD" "$CONTAINER_NAME" /home/user/.local/bin/claude "$@"
