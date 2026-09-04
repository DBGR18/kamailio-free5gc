#!/bin/bash
#
# The actual proof of concept: UE1 calls UE2 through Kamailio, over 5G.
#
# What happens, in order:
#   1. both UEs REGISTER with Kamailio  (SIP over the PDU session)
#   2. UE2 waits for an incoming call
#   3. UE1 sends INVITE; Kamailio looks UE2 up and forwards it
#   4. media (G.711) flows UE1 <-> UE2 while GTP-U carries it
#   5. UE1 hangs up with BYE
#
# In parallel we capture GTP-U on the N3 bridge, because that capture is the
# evidence that the call really used the 5G user plane rather than plain
# container networking.
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

KAMAILIO_IP="10.100.100.10"
N3_BRIDGE="br-poc-core"
CAP="/tmp/poc-n3-gtpu.pcap"

ue_ip() { docker exec "poc-$1" cat /tmp/ue_ip 2>/dev/null; }

UE1_IP=$(ue_ip ue1)
UE2_IP=$(ue_ip ue2)

if [ -z "${UE1_IP}" ] || [ -z "${UE2_IP}" ]; then
    echo "[test] ERROR: a UE has no PDU session. Run ./scripts/01-up.sh first."
    exit 1
fi

echo "=============================================================="
echo " free5gc + Kamailio PoC -- call test"
echo "=============================================================="
echo " UE1 (caller) : ${UE1_IP}"
echo " UE2 (callee) : ${UE2_IP}"
echo " Kamailio     : ${KAMAILIO_IP}:5060  (on the Data Network, over N6)"
echo

# ---------------------------------------------------------------- 0. capture
echo "--- [0/5] capturing GTP-U on N3 (${N3_BRIDGE}) ---"
sudo rm -f "${CAP}"
sudo timeout 60 tcpdump -i "${N3_BRIDGE}" -w "${CAP}" 'udp port 2152' >/dev/null 2>&1 &
TCPDUMP_PID=$!
sleep 2

cleanup() {
    sudo kill "${TCPDUMP_PID}" 2>/dev/null || true
    docker exec poc-ue2 pkill sipp 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------- 1 & 2. registrations
register() {
    local ue="$1" user="$2" ip="$3"
    echo "--- registering ${user} (${ip}) ---"
    docker exec "poc-${ue}" sipp \
        -sf /sipp/register.xml \
        -s "${user}" \
        -i "${ip}" -p 5060 \
        -m 1 -r 1 -timeout 15s \
        -trace_err -error_file "/tmp/${user}-register-err.log" \
        "${KAMAILIO_IP}:5060" 2>&1 | tail -3
}

echo "--- [1/5] UE1 registers with the IMS ---"
register ue1 ue1 "${UE1_IP}"
echo
echo "--- [2/5] UE2 registers with the IMS ---"
register ue2 ue2 "${UE2_IP}"
echo

echo "--- registrar contents (Kamailio usrloc) ---"
docker exec poc-pcscf kamctl ul show 2>/dev/null || \
    docker logs poc-pcscf 2>&1 | grep '\[REG\]' | tail -4
echo

# --------------------------------------------------------- 3. UE2 listens
echo "--- [3/5] UE2 waits for an incoming call ---"
docker exec -d poc-ue2 sipp \
    -sf /sipp/uas_answer.xml \
    -i "${UE2_IP}" -p 5060 \
    -m 1 -timeout 40s -rtp_echo \
    -trace_err -error_file /tmp/ue2-uas-err.log \
    -trace_stat -stf /tmp/ue2-uas-stat.csv
sleep 2

# ------------------------------------------------------------ 4. the call
echo "--- [4/5] UE1 calls UE2 through Kamailio ---"
printf 'SEQUENTIAL\nue1;ue2\n' > /tmp/poc-call.csv
docker cp /tmp/poc-call.csv poc-ue1:/tmp/call.csv

# NB: do not pipe this into tail -- the pipe would return tail's exit status
# and a failed call would be reported as a success.
set +e
docker exec poc-ue1 sipp \
    -sf /sipp/uac_call.xml \
    -inf /tmp/call.csv \
    -i "${UE1_IP}" -p 5060 -mp 6000 \
    -m 1 -r 1 -timeout 40s \
    -trace_err -error_file /tmp/ue1-uac-err.log \
    "${KAMAILIO_IP}:5060" > /tmp/poc-uac-out.txt 2>&1
CALL_RC=$?
set -e
tail -20 /tmp/poc-uac-out.txt
echo

# ------------------------------------------------------------ 5. evidence
echo "--- [5/5] evidence ---"
sleep 2
sudo kill "${TCPDUMP_PID}" 2>/dev/null || true
sleep 1

GTPU_PKTS=$(sudo tcpdump -r "${CAP}" 2>/dev/null | wc -l)
echo "GTP-U packets captured on N3: ${GTPU_PKTS}"
echo
echo "SIP methods found INSIDE the GTP-U tunnels:"
for m in REGISTER INVITE BYE ACK; do
    n=$(sudo tcpdump -r "${CAP}" -n -A 2>/dev/null | grep -c "${m}" || true)
    printf "  %-10s %s\n" "${m}" "${n}"
done
echo
# G.711 media is a stream of equally sized packets; the biggest same-size
# bucket in the capture is the RTP stream.
RTP_PKTS=$(sudo tcpdump -r "${CAP}" -n 2>/dev/null \
    | grep -oE 'length [0-9]+' | sort | uniq -c | sort -rn | head -1 | awk '{print $1}')
echo "Largest same-size packet group (the RTP media stream): ${RTP_PKTS} packets"
echo
echo "Kamailio's view of the call:"
docker logs poc-pcscf 2>&1 | grep -E '\[SIP\]|\[REG\]|\[LOOKUP\]' | tail -12
echo

BYE_SEEN=$(docker logs poc-pcscf 2>&1 | grep -c '\[SIP\] BYE' || true)

if [ "${CALL_RC}" -eq 0 ] && [ "${GTPU_PKTS}" -gt 0 ] && [ "${BYE_SEEN}" -gt 0 ]; then
    echo "=============================================================="
    echo " RESULT: PASS -- call completed and it travelled over GTP-U"
    echo "=============================================================="
    echo " capture saved at ${CAP}"
    echo " inspect with: sudo tcpdump -r ${CAP} -n | head -40"
else
    echo "=============================================================="
    echo " RESULT: FAIL (sipp exit=${CALL_RC}, gtpu packets=${GTPU_PKTS}, BYE seen=${BYE_SEEN})"
    echo "=============================================================="
    echo " error logs inside the UE containers: /tmp/*-err.log"
    exit 1
fi
