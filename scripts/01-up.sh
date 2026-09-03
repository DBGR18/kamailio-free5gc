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
docker compose up -d upf kamailio db nrf amf ausf nssf pcf smf udm udr webui

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

# ------------------------------------------------------------------- 4. UEs
#
# REMOVED 2026-09-04: the UERANSIM gNB/UE containers were deleted when the PoC
# switched to free-ran-ue. Everything above this line still works; bringing a
# UE up again needs the free-ran-ue gNB and UE services added back to
# docker-compose.yaml first. The old UERANSIM version of this section is in the
# cleanup backup (B-ueransim/01-up.sh) if you want it as a reference.
#
echo
echo "[up] core network + IMS are up. NO RAN/UE yet -- free-ran-ue not wired in."
echo "[up] next: add the free-ran-ue gNB and UE services to docker-compose.yaml"
