# S-CSCF: the Serving CSCF.
#
# This is the first of the three CSCF roles to be split out of the single
# general-purpose proxy, because it is the only one that talks to the HSS.
# Splitting it first means the Cx interface built in the previous step gets
# exercised immediately, rather than sitting untested behind another role.
#
# What it does that the old proxy did not:
#   * authenticates REGISTER with IMS AKA instead of accepting anyone
#     (ims_auth, MAR/MAA over Cx)
#   * tells the HSS which S-CSCF is serving the user (SAR/SAA)
#   * keeps its own registrar store (ims_usrloc_scscf), which holds IMPU
#     bindings rather than plain SIP AoRs
FROM debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      kamailio \
      kamailio-ims-modules \
      # ims_usrloc_scscf binds to the presence API at startup, so presence
      # has to be present even though this PoC publishes no presence state.
      kamailio-presence-modules \
      # presence insists on a database; sqlite keeps that to a file rather
      # than another container.
      kamailio-sqlite-modules \
      iproute2 \
      iputils-ping \
      tcpdump \
      sngrep \
      ncat \
      sqlite3 \
 && rm -rf /var/lib/apt/lists/*

# presence connects to its database in mod_init and fails the whole startup
# if the schema is not there. presence-create.sql writes into the "version"
# table, so standard-create.sql has to run first. Build it once here rather
# than at every start.
# Nothing in this PoC publishes presence state -- the module exists only
# because ims_usrloc_scscf binds to its API.
RUN mkdir -p /var/lib/kamailio \
 && cat /usr/share/kamailio/db_sqlite/standard-create.sql \
       /usr/share/kamailio/db_sqlite/presence-create.sql \
    | sqlite3 /var/lib/kamailio/presence.db \
 && chmod 666 /var/lib/kamailio/presence.db

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 6060/udp
ENTRYPOINT ["/entrypoint.sh"]
