#!/bin/bash
#
# Bring the whole PoC up, in the order the pieces actually depend on:
#
#   1. gtp5g kernel module      (without it the UPF refuses to start)
#   2. core network + RAN       (NFs register with the NRF, gNB connects to AMF)
#   3. subscriber provisioning  (the SIMs must exist BEFORE a UE tries to attach,
#                                otherwise authentication fails and the UE gives up)
#   4. the two UEs              (attach, authenticate, get a PDU session)
#
# Step 3 before step 4 is the part that is easy to get wrong: docker compose
# would happily start the UEs first, and they would fail with a MAC failure.
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

# ------------------------------------------------------------- 0. key check
# The UE simulator's config carries a literal OPc that has to match what the
# provisioning scripts compute from OP. Catch a mismatch here rather than as
# an "AUTN validation MAC mismatch" three steps later.
# shellcheck source=scripts/lib-keys.sh
source "${HERE}/scripts/lib-keys.sh"
if ! verify_ue_configs "${HERE}"; then
    echo "[up] key material is inconsistent -- fix the UE configs and re-run"
    exit 1
fi
echo "[up] key material consistent (OPc ${KEY_OPC})"

# ---------------------------------------------------------- 1. kernel module
if ! lsmod | grep -q '^gtp5g'; then
    echo "[up] gtp5g is not loaded -- running scripts/00-setup-gtp5g.sh"
    ./scripts/00-setup-gtp5g.sh
else
    echo "[up] gtp5g already loaded ($(modinfo -F version gtp5g 2>/dev/null || echo '?'))"
fi

# ------------------------------------------------------- 2. core network + RAN
echo "[up] building local images (kamailio, ue-sip)"
docker compose build

echo "[up] starting core network, IMS and RAN"
docker compose up -d upf kamailio db nrf amf ausf nssf pcf smf udm udr webui \
    pyhss-redis pyhss-hss pyhss-api pyhss-diameter

echo "[up] waiting for the webconsole..."
for _ in $(seq 1 60); do
    if curl -sf -o /dev/null http://127.0.0.1:5000/api/subscriber 2>/dev/null \
       || curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5000/ | grep -qE '^(200|401|403|404)$'; then
        break
    fi
    sleep 2
done

# ------------------------------------------------------------ 3. subscribers
./scripts/02-add-subscribers.sh

# ------------------------------------------------------- 3b. IMS subscribers
# The HSS has its own store, unrelated to the UDR above. Both are generated
# from the same IMSI list, which is what keeps the two identity spaces in
# step -- there is no interface between them.
./scripts/04-add-ims-subscribers.sh

# ------------------------------------------------------------- 4. RAN and UEs
echo "[up] starting the gNB"
docker compose up -d gnb

echo "[up] starting the UEs"
docker compose up -d --force-recreate ue1 ue2

echo "[up] waiting for the UEs to get a PDU session..."
FAILED=0
for ue in ue1 ue2; do
    ok=""
    for _ in $(seq 1 90); do
        ip=$(docker exec "poc-${ue}" cat /tmp/ue_ip 2>/dev/null || true)
        if [ -n "${ip}" ]; then
            echo "[up]   ${ue}: ${ip}"
            ok=1
            break
        fi
        sleep 2
    done
    if [ -z "${ok}" ]; then
        echo "[up]   ${ue}: FAILED to get a PDU session"
        echo "[up]   logs: docker logs poc-${ue}"
        FAILED=1
    fi
done

if [ "${FAILED}" -ne 0 ]; then
    echo
    echo "[up] the core is up but at least one UE did not attach."
    exit 1
fi

echo
echo "[up] ready. Both UEs have a PDU session and can reach the IMS."
