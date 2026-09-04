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
# PyHSS splits a subscriber across four resources, and all four are needed
# before a Cx MAR can be answered:
#
#   APN             the data network, referenced by SUBSCRIBER
#   AUC             the key material (K, OPc, AMF, SQN)
#   SUBSCRIBER      ties an IMSI to an AUC entry -- this is what the MAR
#                   handler looks up, and without it the HSS answers
#                   "Subscriber <imsi> unknown in HSS for MAA" no matter how
#                   correct the AUC and IMS_SUBSCRIBER entries are
#   IMS_SUBSCRIBER  the IMS identities (IMPI, IMPU, MSISDN, realms)
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
for res in ims_subscriber subscriber auc apn; do
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

# 1a. The APN. SUBSCRIBER references it, so it has to exist first. One
#     shared entry is enough -- its name matches the 5G side's ims DNN so a
#     reader does not have to hold two vocabularies at once.
apn_rc=$(curl -s -o /tmp/pyhss_apn -w '%{http_code}' -X PUT "${API}/apn/" \
    -H 'Content-Type: application/json' \
    -d '{"apn":"ims","ip_version":0,"apn_ambr_dl":100000,"apn_ambr_ul":100000,
         "qci":5,"arp_priority":1,"arp_preemption_capability":true,
         "arp_preemption_vulnerability":true,"nbiot":false}')
if [ "${apn_rc}" != "200" ] && [ "${apn_rc}" != "201" ]; then
    echo "[ims-sub] ERROR: APN create returned ${apn_rc}"; cat /tmp/pyhss_apn; echo; exit 1
fi
apn_id=$(python3 -c "
import json
print(json.load(open('/tmp/pyhss_apn')).get('apn_id',''))" 2>/dev/null)
echo "[ims-sub] APN 'ims' id=${apn_id}"

for entry in "${SUBSCRIBERS[@]}"; do
    imsi="${entry%%:*}"
    msisdn="${entry##*:}"
    impi="${imsi}@${REALM}"
    impu="sip:${imsi}@${REALM}"

    echo "[ims-sub] ${imsi}"
    echo "[ims-sub]   IMPI ${impi}"
    echo "[ims-sub]   IMPU ${impu}"

    # 1b. Key material. SQN starts one step ahead of the UE's counter, same
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

    auc_id=$(python3 -c "
import json,sys
print(json.load(open('/tmp/pyhss_auc')).get('auc_id',''))" 2>/dev/null)
    if [ -z "${auc_id}" ]; then
        echo "[ims-sub]   ERROR: no auc_id returned"; cat /tmp/pyhss_auc; exit 1
    fi

    # 2. The subscriber record. The Cx MAR handler resolves the IMPI to an
    #    IMSI and then looks this up; the AUC entry alone is not enough.
    sub_rc=$(curl -s -o /tmp/pyhss_sub -w '%{http_code}' -X PUT "${API}/subscriber/" \
        -H 'Content-Type: application/json' \
        -d "{\"imsi\":\"${imsi}\",\"enabled\":true,\"auc_id\":${auc_id},
             \"default_apn\":${apn_id},\"apn_list\":\"${apn_id}\",
             \"msisdn\":\"${msisdn}\",\"ue_ambr_dl\":100000,\"ue_ambr_ul\":100000,
             \"nam\":0,\"roaming_enabled\":true,\"subscribed_rau_tau_timer\":600}")
    if [ "${sub_rc}" != "200" ] && [ "${sub_rc}" != "201" ]; then
        echo "[ims-sub]   ERROR: subscriber create returned ${sub_rc}"
        cat /tmp/pyhss_sub; echo
        exit 1
    fi

    # 3. IMS identities. msisdn_list is what the HSS matches an incoming
    #    IMPU against, so the SIP URI the UE registers with has to be in it.
    #    ifc_path names the initial Filter Criteria template the HSS renders
    #    into the Server-Assignment-Answer. Without it SAR dies inside PyHSS
    #    with "'NoneType' object has no attribute 'split'" and the S-CSCF
    #    answers 500 to a REGISTER it has already authenticated.
    ims_rc=$(curl -s -o /tmp/pyhss_ims -w '%{http_code}' -X PUT "${API}/ims_subscriber/" \
        -H 'Content-Type: application/json' \
        -d "{\"imsi\":\"${imsi}\",\"msisdn\":\"${msisdn}\",
             \"msisdn_list\":\"[\\\"${msisdn}\\\"]\",
             \"scscf_realm\":\"${REALM}\",
             \"pcscf_realm\":\"${REALM}\",
             \"ifc_path\":\"default_ifc.xml\",
             \"sh_profile\":\"default_sh_user_data.xml\"}")
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
