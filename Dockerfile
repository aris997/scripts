FROM debian:13

ARG NEW_USER=agent
ARG SKIP_SNAP=1

ENV DEBIAN_FRONTEND=noninteractive \
    NEW_USER=${NEW_USER} \
    SKIP_SNAP=${SKIP_SNAP}

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget sudo && \
    rm -rf /var/lib/apt/lists/*

COPY debian-server.sh /tmp/debian-server.sh

RUN bash -n /tmp/debian-server.sh
RUN bash /tmp/debian-server.sh

CMD ["bash"]
