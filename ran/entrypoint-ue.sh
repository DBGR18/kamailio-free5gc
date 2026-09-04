#!/bin/bash
#
# UE container entrypoint.
#
# Steps:
#   1. start free-ran-ue's UE, which attaches to the gNB, registers with the
#      AMF and asks for a PDU session;
#   2. wait for the tunnel interface to get an address -- that interface IS
#      the PDU session from an application's point of view;
#   3. route the IMS subnet, and the UE pool, into that interface.
#
# Step 3 is the one that is easy to miss, and free-ran-ue makes it easier to
# miss than UERANSIM did: its ue/tun.go only runs "ip addr add" and "ip link
# set up", so the interface exists with an address but nothing routes to it.
# Without these routes the SIP traffic would leave through the container's
# normal eth0 and reach Kamailio without ever touching the 5G user plane --
# the PoC would "work" while proving nothing.
set -e

UE_CONFIG="${UE_CONFIG:-/ran/config/ue.yaml}"
IMS_SUBNET="${IMS_SUBNET:-10.100.100.0/24}"
UE_SUBNET="${UE_SUBNET:-10.62.0.0/16}"

# ueTunnelDevice in the config is a PREFIX, not the final name: free-ran-ue
# appends a per-UE index so that "-n" can start several UEs in one process.
# A config saying "ueTun" produces an interface called "ueTun0". Match on the
# prefix instead of guessing the suffix.
TUN_PREFIX="${TUN_PREFIX:-ueTun}"

# The UE's log is the only place the discovered P-CSCF address surfaces, so
# it is teed to a file for the wait loop below to read. Process substitution
# rather than a pipe, so $! stays free-ran-ue's own pid and the liveness check
# further down still means something.
UE_LOG=/tmp/ue.log
: > "${UE_LOG}"

echo "[ue] starting free-ran-ue ue with ${UE_CONFIG}"
free-ran-ue ue -c "${UE_CONFIG}" > >(tee -a "${UE_LOG}") 2>&1 &
UE_PID=$!

echo "[ue] waiting for ${TUN_PREFIX}* (PDU session establishment)..."
TUN_IF=""
UE_IP=""
for _ in $(seq 1 90); do
    read -r TUN_IF UE_IP <<<"$(ip -4 -o addr show 2>/dev/null \
        | awk -v p="^${TUN_PREFIX}" '$2 ~ p {split($4,a,"/"); print $2, a[1]; exit}')"
    if [ -n "${UE_IP}" ]; then
        break
    fi
    if ! kill -0 "${UE_PID}" 2>/dev/null; then
        echo "[ue] ERROR: the UE process exited before the tunnel came up"
        exit 1
    fi
    sleep 1
done

if [ -z "${UE_IP}" ]; then
    echo "[ue] ERROR: no ${TUN_PREFIX}* interface came up -- PDU session failed"
    echo "[ue] check the gNB, SMF and UPF logs"
    kill "${UE_PID}" 2>/dev/null || true
    exit 1
fi

echo "[ue] PDU session up: ${TUN_IF} has ${UE_IP}"
echo "${UE_IP}" > /tmp/ue_ip

# The P-CSCF address the network handed back in the PDU Session Establishment
# Accept, in PCO container 000Ch. Nothing here configures it: the UE asked and
# the SMF answered out of the ims DNN's own settings, which is how a real UE
# finds its way into the IMS. Written out for the SIP client to target.
rm -f /tmp/pcscf_ip
PCSCF_IP=$(sed -n 's/.*PDU session P-CSCF: \([0-9][0-9.]*\).*/\1/p' "${UE_LOG}" | tail -1)
if [ -n "${PCSCF_IP}" ]; then
    echo "${PCSCF_IP}" > /tmp/pcscf_ip
    echo "[ue] P-CSCF discovered via PCO: ${PCSCF_IP}"
else
    echo "[ue] no P-CSCF in the PCO -- is pcscf: configured on this DNN?"
fi

# Send IMS-bound traffic (SIP signalling) through the PDU session.
ip route replace "${IMS_SUBNET}" dev "${TUN_IF}" src "${UE_IP}"
echo "[ue] routing ${IMS_SUBNET} (IMS/SIP) via ${TUN_IF}"

# And the UE pool too: RTP media flows directly between the two UEs, so it
# has to go up the tunnel to the UPF, which routes it back down into the
# other UE's tunnel. Without this the media would try to leave via eth0.
ip route replace "${UE_SUBNET}" dev "${TUN_IF}" src "${UE_IP}"
echo "[ue] routing ${UE_SUBNET} (peer UEs / RTP) via ${TUN_IF}"
ip route show

wait "${UE_PID}"
