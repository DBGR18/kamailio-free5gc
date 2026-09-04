#!/bin/bash
#
# The actual proof of concept: UE1 calls UE2 through a three-role IMS, over 5G.
#
# What happens, in order:
#   1. both UEs REGISTER, authenticated with IMS AKA
#        UE -> P-CSCF -> I-CSCF -(UAR/UAA)- HSS
#                     -> S-CSCF -(MAR/MAA, SAR/SAA)- HSS
#   2. UE2 waits for an incoming call
#   3. UE1 sends INVITE addressed to UE2's public identity
#        UE1 -> P-CSCF -> I-CSCF -(LIR/LIA)- HSS
#                      -> S-CSCF -> P-CSCF -> UE2
#   4. media (G.711) flows UE1 <-> UE2 -- directly, never through a CSCF
#   5. UE1 hangs up with BYE, back along the Record-Route set
#
# Two things are captured as evidence, because the interesting claims are not
# "a call connected":
#   * GTP-U on the N3 bridge -- proves signalling AND media crossed the 5G
#     user plane rather than plain container networking
#   * the Cx exchanges in each CSCF's log -- proves all four Cx commands were
#     used and that the call really traversed three separate roles
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"
source "${HERE}/scripts/lib-keys.sh"

REALM="ims.mnc093.mcc208.3gppnetwork.org"
PCSCF_IP="10.100.100.10"
N3_BRIDGE="br-poc-core"
CAP="/tmp/poc-n3-gtpu.pcap"

# IMSI per UE container -- must match scripts/04-add-ims-subscribers.sh.
IMSI_ue1="208930000000001"
IMSI_ue2="208930000000002"

ue_ip() { docker exec "poc-$1" cat /tmp/ue_ip 2>/dev/null; }

UE1_IP=$(ue_ip ue1)
UE2_IP=$(ue_ip ue2)

if [ -z "${UE1_IP}" ] || [ -z "${UE2_IP}" ]; then
    echo "[test] ERROR: a UE has no PDU session. Run ./scripts/01-up.sh first."
    exit 1
fi

echo "=============================================================="
echo " free5gc + IMS PoC -- call test"
echo "=============================================================="
echo " UE1 (caller) : ${UE1_IP}   sip:${IMSI_ue1}@${REALM}"
echo " UE2 (callee) : ${UE2_IP}   sip:${IMSI_ue2}@${REALM}"
echo " P-CSCF       : ${PCSCF_IP}:5060  (on the Data Network, over N6)"
echo " I-CSCF       : 10.100.100.22:4060"
echo " S-CSCF       : 10.100.100.21:6060"
echo

# ---------------------------------------------------------------- 0. capture
echo "--- [0/5] capturing GTP-U on N3 (${N3_BRIDGE}) ---"
sudo rm -f "${CAP}"
sudo timeout 120 tcpdump -i "${N3_BRIDGE}" -w "${CAP}" 'udp port 2152' >/dev/null 2>&1 &
TCPDUMP_PID=$!
sleep 2

cleanup() {
    sudo kill "${TCPDUMP_PID}" 2>/dev/null || true
    docker exec poc-ue2 pkill sipp 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------- 1 & 2. registrations
#
# The scenario cannot take the key material through the CSV: SIPp does not
# expand [fieldN] inside [authentication] at all -- whichever one appears
# first is hoisted out in front of the keyword and the rest are left empty.
# So the values are substituted into a per-UE copy of the scenario instead.
register() {
    local ue="$1" imsi="$2" ip="$3"
    local tmp="/tmp/poc-${ue}-register.xml"

    sed -e "s|@IMPI@|${imsi}@${REALM}|g" \
        -e "s|@K@|${KEY_K}|g" \
        -e "s|@OP@|${KEY_OP}|g" \
        -e "s|@AMF@|${KEY_AMF}|g" \
        ran/sipp/register_aka.xml > "${tmp}"
    docker cp "${tmp}" "poc-${ue}:/tmp/register.xml" >/dev/null

    printf 'SEQUENTIAL\n%s;%s;\n' "${imsi}" "${REALM}" > "/tmp/poc-${ue}-reg.csv"
    docker cp "/tmp/poc-${ue}-reg.csv" "poc-${ue}:/tmp/reg.csv" >/dev/null

    echo "--- registering sip:${imsi}@${REALM} from ${ip} ---"
    # 30 s: a registration is two round trips through the whole chain and
    # PyHSS answers each of MAR and SAR off a queue, not inline.
    docker exec "poc-${ue}" sipp \
        -sf /tmp/register.xml \
        -inf /tmp/reg.csv \
        -i "${ip}" -p 5060 \
        -m 1 -r 1 -timeout 30s \
        -trace_err -error_file "/tmp/${ue}-register-err.log" \
        "${PCSCF_IP}:5060" 2>&1 | tail -3
}

# Every grep below is scoped to this moment onwards. The containers keep
# their logs across runs, so an unscoped count would report the whole history
# of the environment as if it were evidence from this call.
RUN_SINCE=$(date -u +%Y-%m-%dT%H:%M:%S)

echo "--- [1/5] UE1 registers with the IMS ---"
register ue1 "${IMSI_ue1}" "${UE1_IP}"
echo
echo "--- [2/5] UE2 registers with the IMS ---"
register ue2 "${IMSI_ue2}" "${UE2_IP}"
echo

echo "--- what each role recorded ---"
docker logs --since "${RUN_SINCE}" poc-pcscf 2>&1 | grep 'registered' | tail -2
docker logs --since "${RUN_SINCE}" poc-scscf 2>&1 | grep -E 'authenticated|is registered' | tail -4
echo

# --------------------------------------------------------- 3. UE2 listens
echo "--- [3/5] UE2 waits for an incoming call ---"
docker exec -d poc-ue2 sipp \
    -sf /sipp/uas_answer.xml \
    -i "${UE2_IP}" -p 5060 \
    -m 1 -timeout 60s -rtp_echo \
    -trace_err -error_file /tmp/ue2-uas-err.log
sleep 2

# ------------------------------------------------------------ 4. the call
echo "--- [4/5] UE1 calls UE2 through the IMS ---"
printf 'SEQUENTIAL\n%s;%s;%s;\n' "${IMSI_ue1}" "${IMSI_ue2}" "${REALM}" \
    > /tmp/poc-call.csv
docker cp /tmp/poc-call.csv poc-ue1:/tmp/call.csv >/dev/null

# NB: do not pipe this into tail -- the pipe would return tail's exit status
# and a failed call would be reported as a success.
set +e
docker exec poc-ue1 sipp \
    -sf /sipp/uac_call.xml \
    -inf /tmp/call.csv \
    -i "${UE1_IP}" -p 5060 -mp 6000 \
    -m 1 -r 1 -timeout 60s \
    -trace_err -error_file /tmp/ue1-uac-err.log \
    "${PCSCF_IP}:5060" > /tmp/poc-uac-out.txt 2>&1
CALL_RC=$?
set -e
tail -20 /tmp/poc-uac-out.txt
echo

# ------------------------------------------------------------ 5. evidence
echo "--- [5/5] evidence ---"
sleep 2
sudo kill "${TCPDUMP_PID}" 2>/dev/null || true
sleep 1

echo "== the INVITE traversed three separate CSCF roles =="
# The P-CSCF appears twice on purpose: once on the way out from UE1, and
# again on the way in to UE2, because the Path it inserted at registration
# brings the terminating leg back through it. One P-CSCF, two directions.
role_log() { docker logs --since "${RUN_SINCE}" "poc-$1" 2>&1 | sed 's/.*<script>: //'; }
role_log pcscf | grep 'originating INVITE'  | head -1 | sed 's/^/  1. /'
role_log icscf | grep 'LIR to the HSS'      | head -1 | sed 's/^/  2. /'
role_log icscf | grep 'LIA ok'              | head -1 | sed 's/^/  3. /'
role_log scscf | grep -E '^\[SCSCF\] [0-9]+ ->' | head -1 | sed 's/^/  4. /'
role_log pcscf | grep 'terminating INVITE'  | head -1 | sed 's/^/  5. /'
echo

echo "== all four Cx commands were exercised =="
UAR=$(docker logs --since "${RUN_SINCE}" poc-icscf 2>&1 | grep -c 'UAR to the HSS' || true)
LIR=$(docker logs --since "${RUN_SINCE}" poc-icscf 2>&1 | grep -c 'LIR to the HSS' || true)
MAR=$(docker logs --since "${RUN_SINCE}" poc-scscf 2>&1 | grep -c 'MAR to the HSS' || true)
SAR=$(docker logs --since "${RUN_SINCE}" poc-scscf 2>&1 | grep -c 'SAA ok' || true)
printf "  UAR/UAA (I-CSCF, which S-CSCF serves this user) : %s\n" "${UAR}"
printf "  MAR/MAA (S-CSCF, authentication vectors)        : %s\n" "${MAR}"
printf "  SAR/SAA (S-CSCF, register as serving + profile) : %s\n" "${SAR}"
printf "  LIR/LIA (I-CSCF, where is the callee)           : %s\n" "${LIR}"
echo

echo "== it all travelled over the 5G user plane =="
GTPU_PKTS=$(sudo tcpdump -r "${CAP}" 2>/dev/null | wc -l)
echo "  GTP-U packets captured on N3: ${GTPU_PKTS}"
echo "  SIP methods found INSIDE the GTP-U tunnels:"
for m in REGISTER INVITE BYE ACK; do
    n=$(sudo tcpdump -r "${CAP}" -n -A 2>/dev/null | grep -c "${m}" || true)
    printf "    %-10s %s\n" "${m}" "${n}"
done
# G.711 media is a stream of equally sized packets; the biggest same-size
# bucket in the capture is the RTP stream. It never touched a CSCF -- the SDP
# pointed both UEs at each other, so the UPF hairpinned it between the two
# PDU sessions.
RTP_PKTS=$(sudo tcpdump -r "${CAP}" -n 2>/dev/null \
    | grep -oE 'length [0-9]+' | sort | uniq -c | sort -rn | head -1 | awk '{print $1}')
echo "  Largest same-size packet group (the RTP media stream): ${RTP_PKTS} packets"
echo

BYE_SEEN=$(docker logs --since "${RUN_SINCE}" poc-pcscf 2>&1 | grep -c 'BYE' || true)

if [ "${CALL_RC}" -eq 0 ] && [ "${GTPU_PKTS}" -gt 0 ] \
   && [ "${BYE_SEEN}" -gt 0 ] && [ "${LIR}" -gt 0 ]; then
    echo "=============================================================="
    echo " RESULT: PASS -- call completed through P/I/S-CSCF over GTP-U"
    echo "=============================================================="
    echo " capture saved at ${CAP}"
    echo " inspect with: sudo tcpdump -r ${CAP} -n | head -40"
else
    echo "=============================================================="
    echo " RESULT: FAIL (sipp exit=${CALL_RC}, gtpu=${GTPU_PKTS},"
    echo "               BYE seen=${BYE_SEEN}, LIR=${LIR})"
    echo "=============================================================="
    echo " error logs inside the UE containers: /tmp/*-err.log"
    exit 1
fi
