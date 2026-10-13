FROM ubuntu:26.04

# UID/GID of the host user; build_image.sh passes the real values.
ARG USER_UID=501
ARG USER_GID=20

RUN apt-get update \
    && apt-get install -y sudo ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*

# The base image ships an "ubuntu" user (UID/GID 1000) that collides with the
# usual first user on Linux hosts, so drop it. -o lets the group share a GID
# with a system group (e.g. GID 20 on macOS hosts is "dialout" here).
RUN (userdel -r ubuntu 2>/dev/null || true) \
    && groupadd -o -g "${USER_GID}" user \
    && useradd -m -u "${USER_UID}" -g user -s /bin/bash user \
    && echo 'user ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/user \
    && chmod 0440 /etc/sudoers.d/user

RUN install -d -m 0755 -o user -g user \
    /home/user/.claude

USER user
WORKDIR /home/user/workspace

CMD ["bash"]
