# P-CSCF: the UE-facing IMS node.
#
# This container used to be the whole "IMS" -- a single general-purpose SIP
# proxy. Now that the roles are split it keeps the position it always had,
# facing the access network, and does only what a P-CSCF does.
#
# Built from the Debian package rather than a third-party image so that the
# version is pinned by the base image and the build is reproducible offline
# once the layer is cached.
FROM debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      kamailio \
      kamailio-ims-modules \
      # http_client, to reach the AF shim.
      kamailio-utils-modules \
      iproute2 \
      iputils-ping \
      tcpdump \
      sngrep \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5060/udp
ENTRYPOINT ["/entrypoint.sh"]
