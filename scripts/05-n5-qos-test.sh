#!/bin/bash
#
# Does an AF request over N5 actually reach the user plane?
#
# This exercises the policy half of the PoC without involving SIP at all: the
# AF is driven directly, so a failure here is a 5G core problem and not an IMS
# one. The chain under test is
#
#   AF --Npcf_PolicyAuthorization--> PCF --Npcf_SMPolicyControl--> SMF
#                                                --PFCP--> UPF --> gtp5g
#
# and the check is at the far end, in the kernel: the PDR/QER pair that gtp5g
# is actually matching packets against. That is deliberate. free5gc implements
# the QoS spec surface but enforces none of it -- there is no rate limiting and
# no guaranteed bitrate behind those numbers -- so measuring throughput would
# prove nothing either way. "The rule was installed" is the strongest true
# claim available, and this script makes exactly that claim.
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

CALL_ID="qos-test-$$"
UE_PORT=6000
PEER_PORT=6000
BW="64 Kbps"

source "${HERE}/scripts/lib-gtp5g.sh"
if ! ensure_gtp5g_reader; then
    echo "[qos] ERROR: no gogtp5g-tunnel, and it could not be built."
    echo "[qos] Set TUNNEL_BIN to an existing copy and re-run."
    exit 1
fi
if ! docker inspect -f '{{.State.Pid}}' poc-upf >/dev/null 2>&1; then
    echo "[qos] ERROR: poc-upf is not running. Run ./scripts/01-up.sh first."
    exit 1
fi

rules() { gtp5g_rules "$1"; }

UE1_IP=$(docker exec poc-ue1 cat /tmp/ue_ip 2>/dev/null || true)
UE2_IP=$(docker exec poc-ue2 cat /tmp/ue_ip 2>/dev/null || true)
if [ -z "${UE1_IP}" ] || [ -z "${UE2_IP}" ]; then
    echo "[qos] ERROR: a UE has no PDU session. Run ./scripts/01-up.sh first."
    exit 1
fi

echo "=============================================================="
echo " N5 QoS test -- does an AF request reach gtp5g?"
echo "=============================================================="
echo " UE       : ${UE1_IP}:${UE_PORT}   (imsi-208930000000001)"
echo " peer     : ${UE2_IP}:${PEER_PORT}"
echo " asking for ${BW} guaranteed, both directions"
echo

before=$(rules pdr | python3 -c 'import json,sys; d=json.load(sys.stdin) or []; print(len(d))')
echo "--- [1/4] before: ${before} PDRs installed ---"

# From here on a reservation may exist, and it has to be given back even if
# the checks below fail -- otherwise a failed run leaves a PCC rule installed
# and the next run starts from a state it did not create.
release() {
    docker exec poc-af curl -s -o /dev/null -X POST http://localhost:8090/call/delete \
        -H 'Content-Type: application/json' -d "{\"callId\":\"${CALL_ID}\"}" 2>/dev/null || true
}
trap release EXIT

echo "--- [2/4] AF -> PCF: authorise the media flow ---"
body=$(printf '{"callId":"%s","supi":"imsi-208930000000001","ueAddr":"%s","uePort":%d,"peerAddr":"%s","peerPort":%d,"bwUl":"%s","bwDl":"%s"}' \
    "${CALL_ID}" "${UE1_IP}" "${UE_PORT}" "${UE2_IP}" "${PEER_PORT}" "${BW}" "${BW}")
code=$(docker exec poc-af curl -s -o /tmp/af-out.txt -w '%{http_code}' \
    -X POST http://localhost:8090/call -H 'Content-Type: application/json' -d "${body}")
if [ "${code}" != "200" ]; then
    echo "[qos] FAIL: the AF returned ${code}"
    docker logs --tail 20 poc-af
    exit 1
fi
echo "    app session created"
sleep 3

echo "--- [3/4] what gtp5g is matching on now ---"
rules pdr > /tmp/qos-pdr.json
rules qer > /tmp/qos-qer.json

RESULT=$(UE_IP="${UE1_IP}" PEER_IP="${UE2_IP}" UE_PORT="${UE_PORT}" PEER_PORT="${PEER_PORT}" \
python3 <<'PY'
import json, os, sys

ue, peer = os.environ["UE_IP"], os.environ["PEER_IP"]
uport, pport = int(os.environ["UE_PORT"]), int(os.environ["PEER_PORT"])

pdrs = json.load(open("/tmp/qos-pdr.json")) or []
qers = {q["ID"]: q for q in (json.load(open("/tmp/qos-qer.json")) or [])}

def ports(v):
    # gtp5g reports each port as a range, so a single port arrives as [[6000]].
    out = []
    for r in v or []:
        out.extend(r if isinstance(r, list) else [r])
    return out

def matches(fd, src, sport, dst, dport):
    return (fd.get("Proto") == 17
            and (fd.get("Src") or {}).get("IP") == src
            and (fd.get("Dst") or {}).get("IP") == dst
            and sport in ports(fd.get("SrcPorts"))
            and dport in ports(fd.get("DstPorts")))

found = []
for p in pdrs:
    fd = ((p.get("PDI") or {}).get("SDF") or {}).get("FD")
    if not fd:
        continue
    if matches(fd, ue, uport, peer, pport):
        found.append(("uplink", p))
    elif matches(fd, peer, pport, ue, uport):
        found.append(("downlink", p))

if not found:
    print("FAIL no PDR carries the media flow")
    sys.exit(0)

lines, ok = [], True
seen_qers = set()
for direction, p in sorted(found):
    qids = p.get("QERID") or []
    lines.append("    PDR %-3s %-9s precedence %-4s -> QER %s"
                 % (p.get("ID"), direction, p.get("Precedence"), qids))
    seen_qers.update(qids)

for qid in sorted(seen_qers):
    q = qers.get(qid)
    if q is None:
        lines.append("    QER %s is referenced but absent" % qid)
        ok = False
        continue
    gbr, mbr = q.get("GBR") or {}, q.get("MBR") or {}
    lines.append("    QER %-3s QFI %-3s GBR %s/%s Kbps  MBR %s/%s Kbps"
                 % (qid, q.get("QFI"),
                    gbr.get("UL_Kbps"), gbr.get("DL_Kbps"),
                    mbr.get("UL_Kbps"), mbr.get("DL_Kbps")))
    if not gbr.get("UL_Kbps"):
        lines.append("    QER %s carries no guaranteed bit rate" % qid)
        ok = False

if len(found) != 2:
    lines.append("    expected one PDR per direction, got %d" % len(found))
    ok = False

print(("PASS" if ok else "FAIL") + " " + "\n".join(lines))
PY
)
VERDICT="${RESULT%% *}"
echo "${RESULT#* }"
echo

echo "--- [4/4] tearing the reservation down ---"
release
sleep 3
after=$(rules pdr | python3 -c 'import json,sys; d=json.load(sys.stdin) or []; print(len(d))')
echo "    ${after} PDRs installed (was ${before} before the request)"
echo

if [ "${VERDICT}" = "PASS" ] && [ "${after}" = "${before}" ]; then
    echo "=============================================================="
    echo " RESULT: PASS -- the AF's request became a gtp5g rule, and"
    echo "         releasing it removed the rule again"
    echo "=============================================================="
else
    echo "=============================================================="
    echo " RESULT: FAIL (rule check ${VERDICT}, PDRs before ${before} after ${after})"
    echo "=============================================================="
    echo " AF log:    docker logs poc-af"
    echo " PCF log:   docker logs poc-pcf | grep PolAuth"
    echo " SMF log:   docker logs poc-smf | grep -i pccrule"
    exit 1
fi
