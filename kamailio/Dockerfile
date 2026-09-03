# Kamailio acting as the (very simplified) IMS core for this PoC.
#
# Built from the Debian package rather than a third-party image so that the
# version is pinned by the base image and the build is reproducible offline
# once the layer is cached.
FROM debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      kamailio \
      iproute2 \
      iputils-ping \
      tcpdump \
      sngrep \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5060/udp
ENTRYPOINT ["/entrypoint.sh"]
