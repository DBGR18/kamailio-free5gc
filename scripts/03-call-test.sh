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
N3_BRIDGE="br-poc-core"
CAP="/tmp/poc-n3-gtpu.pcap"

# IMSI per UE container -- must match scripts/04-add-ims-subscribers.sh.
IMSI_ue1="208930000000001"
IMSI_ue2="208930000000002"

# "|| true" is load-bearing. Under set -e an assignment from a command
# substitution takes the substitution's exit status, so a missing file would
# end the script right here -- silently, before any of the checks below could
# explain what was wrong.
ue_ip()    { docker exec "poc-$1" cat /tmp/ue_ip 2>/dev/null || true; }
ue_pcscf() { docker exec "poc-$1" cat /tmp/pcscf_ip 2>/dev/null || true; }

UE1_IP=$(ue_ip ue1)
UE2_IP=$(ue_ip ue2)

if [ -z "${UE1_IP}" ] || [ -z "${UE2_IP}" ]; then
    echo "[test] ERROR: a UE has no PDU session. Run ./scripts/01-up.sh first."
    exit 1
fi

# Each UE uses the P-CSCF the network gave it, not a constant in this script.
# That is the whole point of the PCO exchange: if discovery breaks, this test
# has nowhere to send SIP and says so, instead of quietly falling back to an
# address that happens to be right.
UE1_PCSCF=$(ue_pcscf ue1)
UE2_PCSCF=$(ue_pcscf ue2)
if [ -z "${UE1_PCSCF}" ] || [ -z "${UE2_PCSCF}" ]; then
    echo "[test] ERROR: a UE did not learn a P-CSCF address."
    echo "[test] The UE asks for it in the PDU Session Establishment Request"
    echo "[test] and the SMF answers from the ims DNN's pcscf: setting."
    echo "[test] check: docker logs poc-ue1 | grep P-CSCF"
    exit 1
fi

# The claim is that the UE was told, not configured. Worth asserting rather
# than trusting, since a stray pcscf entry in the UE config would make the
# whole exchange decorative.
if grep -qi "pcscf" config/ue-ue1.yaml config/ue-ue2.yaml 2>/dev/null; then
    echo "[test] ERROR: a UE config mentions a P-CSCF; discovery proves nothing."
    exit 1
fi

echo "=============================================================="
echo " free5gc + IMS PoC -- call test"
echo "=============================================================="
echo " UE1 (caller) : ${UE1_IP}   sip:${IMSI_ue1}@${REALM}"
echo " UE2 (callee) : ${UE2_IP}   sip:${IMSI_ue2}@${REALM}"
echo " P-CSCF       : ${UE1_PCSCF}:5060  learned from the network, not configured"
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
    [ -n "${QOS_SAMPLER:-}" ] && kill "${QOS_SAMPLER}" 2>/dev/null
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
    local ue="$1" imsi="$2" ip="$3" pcscf="$4"
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
        "${pcscf}:5060" 2>&1 | tail -3
}

# Every grep below is scoped to this moment onwards. The containers keep
# their logs across runs, so an unscoped count would report the whole history
# of the environment as if it were evidence from this call.
RUN_SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "--- [1/5] UE1 registers with the IMS ---"
register ue1 "${IMSI_ue1}" "${UE1_IP}" "${UE1_PCSCF}"
echo
echo "--- [2/5] UE2 registers with the IMS ---"
register ue2 "${IMSI_ue2}" "${UE2_IP}" "${UE2_PCSCF}"
echo

echo "--- what each role recorded ---"
docker logs --since "${RUN_SINCE}" poc-pcscf 2>&1 | grep 'registered' | tail -2
docker logs --since "${RUN_SINCE}" poc-scscf 2>&1 | grep -E 'authenticated|is registered' | tail -4
echo

# --------------------------------------------------------- 3. UE2 listens
# The QoS rules only exist while the call is up, and the BYE at the end of
# this script takes them away again -- so they have to be sampled from the
# kernel while sipp is still talking. Optional: without the reader this test
# still checks everything else.
QOS_DIR=/tmp/poc-qos-samples
source "${HERE}/scripts/lib-gtp5g.sh"
UPF_PID=$(docker inspect -f '{{.State.Pid}}' poc-upf 2>/dev/null || true)
QOS_SAMPLER=""
if ensure_gtp5g_reader && [ -n "${UPF_PID}" ]; then
    rm -rf "${QOS_DIR}"; mkdir -p "${QOS_DIR}"
    (
        for i in $(seq 1 60); do
            sudo nsenter -t "${UPF_PID}" -n "${TUNNEL_BIN}" list pdr \
                > "${QOS_DIR}/${i}.json" 2>/dev/null || true
            sleep 0.5
        done
    ) &
    QOS_SAMPLER=$!
fi

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
    "${UE1_PCSCF}:5060" > /tmp/poc-uac-out.txt 2>&1
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

echo "== the P-CSCF reserved QoS for the media, as an AF over N5 =="
role_log pcscf | grep -E 'AF: reserving|AF: released' | sed 's/^/  /'
if [ -n "${QOS_SAMPLER}" ]; then
    kill "${QOS_SAMPLER}" 2>/dev/null || true
    QOS_VERDICT=$(UE1="${UE1_IP}" UE2="${UE2_IP}" QOS_DIR="${QOS_DIR}" python3 <<'QOSPY'
import glob, json, os

ue1, ue2 = os.environ["UE1"], os.environ["UE2"]

def ports(v):
    out = []
    for r in v or []:
        out.extend(r if isinstance(r, list) else [r])
    return out

def media(fd):
    if not fd or fd.get("Proto") != 17:
        return False
    src = (fd.get("Src") or {}).get("IP")
    dst = (fd.get("Dst") or {}).get("IP")
    return {src, dst} == {ue1, ue2} and 6000 in ports(fd.get("SrcPorts"))

best = []
for path in sorted(glob.glob(os.path.join(os.environ["QOS_DIR"], "*.json"))):
    try:
        with open(path) as fh:
            pdrs = json.load(fh) or []
    except Exception:
        continue
    hit = [p for p in pdrs
           if media(((p.get("PDI") or {}).get("SDF") or {}).get("FD"))]
    if len(hit) > len(best):
        best = hit

if not best:
    print("NONE  no dedicated PDR for the media flow was ever installed")
else:
    lines = ["%d dedicated PDRs were installed while the call was up:" % len(best)]
    for p in sorted(best, key=lambda x: x.get("ID")):
        fd = ((p.get("PDI") or {}).get("SDF") or {}).get("FD")
        lines.append("    PDR %-3s session of %-10s  %s:%s -> %s:%s  precedence %s  QER %s"
                     % (p.get("ID"), (p.get("PDI") or {}).get("UEAddr"),
                        (fd.get("Src") or {}).get("IP"), ports(fd.get("SrcPorts"))[0],
                        (fd.get("Dst") or {}).get("IP"), ports(fd.get("DstPorts"))[0],
                        p.get("Precedence"), p.get("QERID")))
    print("OK  " + "\\n".join(lines))
QOSPY
)
    printf '  %b\n' "${QOS_VERDICT#* }"
    QOS_OK="${QOS_VERDICT%% *}"
else
    echo "  (skipped: no gogtp5g-tunnel and no Go toolchain to build one)"
    QOS_OK="SKIP"
fi
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

if [ "${QOS_OK}" = "NONE" ]; then
    CALL_RC=1
fi

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
