#!/bin/bash
#
# Register the two PoC SIM cards in the free5gc subscriber database.
#
# The keys here must match the UE simulator config (free-ran-ue: config/ue.yaml,
# fields authenticationSubscription.encPermanentKey / encOpcKey),
# otherwise 5G authentication fails and the UE never gets as far as a PDU
# session -- let alone a SIP call.
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Key material, all derived from one OP; see the file for why OP and not OPc.
# shellcheck source=scripts/lib-keys.sh
source "${HERE}/scripts/lib-keys.sh"
WEBUI="${WEBUI:-http://127.0.0.1:5000}"
PLMN="20893"
# ueId:msisdn -- the MSISDN (GPSI) must be unique per subscriber, the
# webconsole rejects duplicates with "duplicate gpsi".
SUBSCRIBERS=("imsi-208930000000001:0900000001" "imsi-208930000000002:0900000002")

echo "[sub] logging in to the webconsole at ${WEBUI}"
TOKEN=$(curl -s -X POST "${WEBUI}/api/login" \
    -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"free5gc"}' | jq -r '.access_token // empty')

if [ -z "${TOKEN}" ]; then
    echo "[sub] ERROR: could not log in. Is the webconsole up? (docker compose ps webui)"
    exit 1
fi

for entry in "${SUBSCRIBERS[@]}"; do
    ueid="${entry%%:*}"
    msisdn="${entry##*:}"
    body=$(python3 - "${HERE}/scripts/subscriber-template.json" "${ueid}" "${PLMN}" "${msisdn}" \
        "${KEY_K}" "${KEY_OPC}" "${KEY_AMF}" "${KEY_SQN_HEX}" <<'PY'
import json, sys
tpl, ueid, plmn, msisdn = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
key_k, key_opc, key_amf, key_sqn = sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8]
d = json.load(open(tpl))
d["ueId"] = ueid
d["plmnID"] = plmn
d["AccessAndMobilitySubscriptionData"]["gpsis"] = ["msisdn-" + msisdn]

# The template stores its key material in the milenage OP field, but the UE
# declares it as OPc -- different inputs to Milenage, and leaving them
# mismatched fails with "AUTN validation MAC mismatch". Take the values from
# lib-keys.sh instead of the template so that every component is provisioned
# from the same OP.
auth = d["AuthenticationSubscription"]
auth["permanentKey"]["permanentKeyValue"] = key_k
auth["opc"]["opcValue"] = key_opc
auth["milenage"]["op"]["opValue"] = ""
auth["authenticationManagementField"] = key_amf

# SQN handling: a 3GPP sequence number splits into SEQ (high 43 bits) and
# IND (low 5 bits), and the UE accepts a vector only when its SEQ is
# just ahead of the SEQ it has seen. The UE starts at zero, so:
#   * the template's large default (0x16f3b3f70fc2) is rejected as "out of
#     range" -- far too far ahead;
#   * zero is rejected too, because free5gc increments SQN by one and any
#     value below 32 still has SEQ == 0, i.e. it never looks fresh.
# 0x23 puts SEQ at 1 -- one step ahead of the UE -- which both sides accept.
auth["sequenceNumber"] = key_sqn
# The extra QoS flow rules in the template are unrelated to this PoC and only
# add moving parts, so drop them.
d.pop("FlowRules", None)
d.pop("QosFlows", None)
print(json.dumps(d))
PY
)
    # Delete first so that re-running this script actually re-applies the
    # credentials instead of returning 409 and silently keeping stale ones.
    curl -s -o /dev/null -X DELETE "${WEBUI}/api/subscriber/${ueid}/${PLMN}" \
        -H "Token: ${TOKEN}" || true

    code=$(curl -s -o /tmp/sub_resp -w '%{http_code}' \
        -X POST "${WEBUI}/api/subscriber/${ueid}/${PLMN}" \
        -H 'Content-Type: application/json' \
        -H "Token: ${TOKEN}" \
        -d "${body}")
    if [ "${code}" = "201" ] || [ "${code}" = "200" ]; then
        echo "[sub] ${ueid} added"
    elif [ "${code}" = "409" ]; then
        # Already provisioned from an earlier run -- this script is meant to
        # be safe to re-run.
        echo "[sub] ${ueid} already present"
    else
        echo "[sub] ${ueid} -> HTTP ${code}: $(cat /tmp/sub_resp)"
    fi
done

echo "[sub] current subscribers:"
curl -s -H "Token: ${TOKEN}" "${WEBUI}/api/subscriber" | jq -r '.[] | "  " + .ueId'
