#!/bin/bash
#
# Provision the IMS subscribers into PyHSS.
#
# This is the counterpart to 02-add-subscribers.sh, which fills free5gc's UDR.
# The two stores hold different data and there is no interface between them:
# the UDR knows SUPI / K / OPc / slices, the HSS knows IMPI / IMPU / MSISDN.
#
# What keeps them consistent is a naming rule, not a data path. The UE has no
# ISIM, so it derives its IMS identities from the IMSI (TS 23.003 13.4B):
#
#   IMSI  208930000000001
#     IMPI  208930000000001@ims.mnc093.mcc208.3gppnetwork.org
#     IMPU  sip:208930000000001@ims.mnc093.mcc208.3gppnetwork.org
#
# Both sides are therefore generated from the same IMSI list below, and the
# derivation is done here in code rather than written out by hand -- that is
# what makes drift impossible rather than merely unlikely.
#
# PyHSS splits the subscriber across two resources: AUC holds the key
# material, IMS_SUBSCRIBER holds the identities and points back at the AUC
# entry by IMSI.
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

# Key material, all derived from one OP. See the file for why OP and not OPc.
# shellcheck source=scripts/lib-keys.sh
source "${HERE}/scripts/lib-keys.sh"

API="${PYHSS_API:-http://127.0.0.1:8080}"

MCC="208"
MNC="93"
# 3GPP requires the MNC to be three digits in these FQDNs, zero-padded when
# the PLMN uses a two-digit MNC (TS 23.003 13.2). 93 becomes 093.
MNC3=$(printf '%03d' "${MNC}")
REALM="ims.mnc${MNC3}.mcc${MCC}.3gppnetwork.org"

# Key material comes from lib-keys.sh, same source as the 5G side.
K="${KEY_K}"
OPC="${KEY_OPC}"
AMF_FIELD="${KEY_AMF}"

# IMSI:MSISDN -- must match SUBSCRIBERS in 02-add-subscribers.sh.
SUBSCRIBERS=(
    "208930000000001:0900000001"
    "208930000000002:0900000002"
)

echo "[ims-sub] waiting for the PyHSS API at ${API}"
for _ in $(seq 1 60); do
    if curl -sf -o /dev/null "${API}/oam/ping" 2>/dev/null; then
        break
    fi
    sleep 2
done

if ! curl -sf -o /dev/null "${API}/oam/ping" 2>/dev/null; then
    echo "[ims-sub] ERROR: the PyHSS API never came up"
    echo "[ims-sub] check: docker logs poc-pyhss-api"
    exit 1
fi

# Remove anything left from a previous run so this script is re-runnable.
for res in ims_subscriber auc; do
    ids=$(curl -sf "${API}/${res}/list" 2>/dev/null \
        | python3 -c "
import sys, json
try:
    for row in json.load(sys.stdin):
        print(row.get('${res}_id'))
except Exception:
    pass" 2>/dev/null || true)
    for id in ${ids}; do
        [ -n "${id}" ] && curl -sf -o /dev/null -X DELETE "${API}/${res}/${id}" 2>/dev/null || true
    done
done

for entry in "${SUBSCRIBERS[@]}"; do
    imsi="${entry%%:*}"
    msisdn="${entry##*:}"
    impi="${imsi}@${REALM}"
    impu="sip:${imsi}@${REALM}"

    echo "[ims-sub] ${imsi}"
    echo "[ims-sub]   IMPI ${impi}"
    echo "[ims-sub]   IMPU ${impu}"

    # 1. Key material. SQN starts one step ahead of the UE's counter, same
    #    reasoning as the 5G side: any value under 32 leaves SEQ at 0, which
    #    the UE reads as "not fresh".
    auc_rc=$(curl -s -o /tmp/pyhss_auc -w '%{http_code}' -X PUT "${API}/auc/" \
        -H 'Content-Type: application/json' \
        -d "{\"ki\":\"${K}\",\"opc\":\"${OPC}\",\"amf\":\"${AMF_FIELD}\",
             \"sqn\":${KEY_SQN_DEC},\"imsi\":\"${imsi}\",\"algo\":\"milenage\",
             \"batch_name\":\"poc\",\"sim_vendor\":\"poc\"}")
    if [ "${auc_rc}" != "200" ] && [ "${auc_rc}" != "201" ]; then
        echo "[ims-sub]   ERROR: AUC create returned ${auc_rc}"
        cat /tmp/pyhss_auc; echo
        exit 1
    fi

    # 2. IMS identities. msisdn_list is what the HSS matches an incoming
    #    IMPU against, so the SIP URI the UE registers with has to be in it.
    ims_rc=$(curl -s -o /tmp/pyhss_ims -w '%{http_code}' -X PUT "${API}/ims_subscriber/" \
        -H 'Content-Type: application/json' \
        -d "{\"imsi\":\"${imsi}\",\"msisdn\":\"${msisdn}\",
             \"msisdn_list\":\"[\\\"${msisdn}\\\"]\",
             \"scscf_realm\":\"${REALM}\",
             \"pcscf_realm\":\"${REALM}\"}")
    if [ "${ims_rc}" != "200" ] && [ "${ims_rc}" != "201" ]; then
        echo "[ims-sub]   ERROR: IMS subscriber create returned ${ims_rc}"
        cat /tmp/pyhss_ims; echo
        exit 1
    fi
done

echo
echo "[ims-sub] subscribers now in the HSS:"
curl -sf "${API}/ims_subscriber/list" | python3 -c "
import sys, json
for row in json.load(sys.stdin):
    print('  imsi=%s  msisdn=%s' % (row.get('imsi'), row.get('msisdn')))
"
