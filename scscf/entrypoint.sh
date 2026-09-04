#!/bin/bash
#
# S-CSCF container entrypoint.
#
# cdp dials the HSS as soon as Kamailio starts and gives up on the peer if it
# is not there yet, so wait for the Diameter port before starting rather than
# relying on compose's depends_on, which only waits for the container.
set -e

HSS_HOST="${HSS_HOST:-hss.ims.mnc093.mcc208.3gppnetwork.org}"
HSS_PORT="${HSS_PORT:-3868}"

echo "[scscf] waiting for the HSS at ${HSS_HOST}:${HSS_PORT}..."
for _ in $(seq 1 60); do
    if (echo > "/dev/tcp/${HSS_HOST}/${HSS_PORT}") 2>/dev/null; then
        echo "[scscf] HSS is accepting connections"
        break
    fi
    sleep 1
done

if ! (echo > "/dev/tcp/${HSS_HOST}/${HSS_PORT}") 2>/dev/null; then
    echo "[scscf] ERROR: ${HSS_HOST}:${HSS_PORT} never became reachable"
    exit 1
fi

# The UE pool sits behind the UPF, not on any link this container has, so
# without an explicit route the 401 challenge and the 200 leave via the
# default gateway and never arrive. The symptom is a REGISTER that
# retransmits forever while the S-CSCF log shows it answering happily.
UE_SUBNET="${UE_SUBNET:-10.62.0.0/16}"
UPF_DN_IP="${UPF_DN_IP:-10.100.100.30}"
echo "[scscf] routing ${UE_SUBNET} via UPF at ${UPF_DN_IP}"
ip route replace "${UE_SUBNET}" via "${UPF_DN_IP}"

echo "[scscf] starting kamailio"
exec kamailio -DD -E -f /etc/kamailio/kamailio.cfg
