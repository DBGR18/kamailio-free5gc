# I-CSCF: the Interrogating CSCF.
#
# The network's front door. Its whole job is to answer "which S-CSCF serves
# this user?", and it answers by asking the HSS -- which is why it is the
# only other role that speaks Cx:
#
#   UAR/UAA   on REGISTER: assign or look up the serving S-CSCF
#   LIR/LIA   on an incoming call: find where the callee is registered
#
# Those two commands are the half of Cx the S-CSCF never uses, so this
# container is what finally exercises the whole interface.
FROM debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      kamailio \
      kamailio-ims-modules \
      kamailio-sqlite-modules \
      sqlite3 \
      iproute2 \
      iputils-ping \
      tcpdump \
      sngrep \
 && rm -rf /var/lib/apt/lists/*

# ims_icscf keeps the S-CSCF pool in a database rather than in config, so
# that the set can change without restarting. Build it at image time.
COPY schema.sql /tmp/schema.sql
COPY seed.sql /tmp/seed.sql
RUN mkdir -p /var/lib/kamailio \
 && cat /usr/share/kamailio/db_sqlite/standard-create.sql /tmp/schema.sql /tmp/seed.sql \
    | sqlite3 /var/lib/kamailio/icscf.db \
 && chmod 666 /var/lib/kamailio/icscf.db \
 && rm /tmp/schema.sql /tmp/seed.sql

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 4060/udp
ENTRYPOINT ["/entrypoint.sh"]
