FROM debian:13

ARG NEW_USER=agent
ARG SKIP_SNAP=1
ARG SKIP_DOCKER=1

ENV DEBIAN_FRONTEND=noninteractive \
    NEW_USER=${NEW_USER} \
    SKIP_SNAP=${SKIP_SNAP} \
    SKIP_DOCKER=${SKIP_DOCKER}

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget sudo && \
    rm -rf /var/lib/apt/lists/*

COPY debian-docker.sh /tmp/debian-docker.sh

RUN bash -n /tmp/debian-docker.sh
RUN SKIP_SNAP=1 SKIP_DOCKER=1 bash /tmp/debian-docker.sh

CMD ["bash"]
