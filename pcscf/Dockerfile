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

# Kamailio comes from the project's own repository rather than from Debian.
# Trixie ships 6.0.1, which is a year and a half behind; the 6.1 branch here is
# current and carries the same set of module packages.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://deb.kamailio.org/kamailiodebkey.gpg \
      -o /etc/apt/keyrings/kamailio.asc \
 && echo "deb [signed-by=/etc/apt/keyrings/kamailio.asc] \
http://deb.kamailio.org/kamailio61 trixie main" \
      > /etc/apt/sources.list.d/kamailio.list \
 && rm -rf /var/lib/apt/lists/*

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
