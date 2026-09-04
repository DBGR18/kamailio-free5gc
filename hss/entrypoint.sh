#!/bin/bash
#
# HSS container entrypoint.
#
# All this does before starting the daemon is mint a TLS certificate whose
# owner matches the Diameter Identity in hss.conf. freeDiameter refuses to
# start without TLS credentials ("Missing private key configuration for TLS")
# even when every peer connects over plain TCP, and it rejects a certificate
# whose owner does not match Identity -- which the image's own certificate,
# issued to "hss.gradiant", does not.
#
# The certificate is generated fresh into a tmpfs on every start. It is never
# used to protect anything in this PoC: the Cx peers connect with No_TLS.
set -e

IDENTITY="${DIAMETER_IDENTITY:-hss.ims.mnc093.mcc208.3gppnetwork.org}"
TLS_DIR="/tmp/hss-tls"

mkdir -p "${TLS_DIR}"

if [ ! -f "${TLS_DIR}/hss.cert.pem" ]; then
    echo "[hss] generating a self-signed certificate for ${IDENTITY}"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "${TLS_DIR}/hss.key.pem" \
        -out    "${TLS_DIR}/hss.cert.pem" \
        -subj   "/CN=${IDENTITY}" >/dev/null 2>&1
fi

# open5gs-hssd gives up and exits if MongoDB is not accepting connections at
# the moment it starts, and it exits with status 0 while doing it -- so the
# container looks like it stopped cleanly rather than failed. compose's
# depends_on only waits for the database container to start, not for mongod
# to be listening, so wait for it here.
DB_HOST="${DB_HOST:-hss-db}"
DB_PORT="${DB_PORT:-27017}"

echo "[hss] waiting for ${DB_HOST}:${DB_PORT}..."
for _ in $(seq 1 60); do
    if (echo > "/dev/tcp/${DB_HOST}/${DB_PORT}") 2>/dev/null; then
        echo "[hss] database is up"
        break
    fi
    sleep 1
done

if ! (echo > "/dev/tcp/${DB_HOST}/${DB_PORT}") 2>/dev/null; then
    echo "[hss] ERROR: ${DB_HOST}:${DB_PORT} never became reachable"
    exit 1
fi

echo "[hss] Diameter identity: ${IDENTITY}"
echo "[hss] starting open5gs-hssd"
exec /opt/open5gs/bin/open5gs-hssd -c /open5gs/hss.yaml
