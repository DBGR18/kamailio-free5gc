#!/bin/bash
#
# Provision the IMS subscribers into the HSS.
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
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

MCC="208"
MNC="93"
# 3GPP requires the MNC to be three digits in these FQDNs, zero-padded when
# the PLMN uses a two-digit MNC (TS 23.003 13.2). 93 becomes 093.
MNC3=$(printf '%03d' "${MNC}")
REALM="ims.mnc${MNC3}.mcc${MCC}.3gppnetwork.org"

# Same key material as the 5G side; see scripts/02-add-subscribers.sh.
K="8baf473f2f8fd09487cccbd7097c6862"
OPC="8e27b6af0e692e750f32667a3b14605d"
AMF_FIELD="8000"

# IMSI:MSISDN -- must match SUBSCRIBERS in 02-add-subscribers.sh.
SUBSCRIBERS=(
    "208930000000001:0900000001"
    "208930000000002:0900000002"
)

echo "[ims-sub] waiting for the HSS database..."
for _ in $(seq 1 30); do
    if docker exec poc-hss-db mongo --quiet --eval 'db.runCommand({ping:1}).ok' >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

for entry in "${SUBSCRIBERS[@]}"; do
    imsi="${entry%%:*}"
    msisdn="${entry##*:}"
    impi="${imsi}@${REALM}"
    impu="sip:${imsi}@${REALM}"

    echo "[ims-sub] ${imsi}"
    echo "[ims-sub]   IMPI ${impi}"
    echo "[ims-sub]   IMPU ${impu}"

    docker exec -i poc-hss-db mongo --quiet open5gs >/dev/null <<EOF
db.subscribers.deleteOne({ imsi: "${imsi}" });
db.subscribers.insertOne({
  imsi: "${imsi}",
  msisdn: [ "${msisdn}" ],
  imeisv: [],
  mme_host: [],
  mme_realm: [],
  purge_flag: [],
  security: {
    k:   "${K}",
    opc: "${OPC}",
    amf: "${AMF_FIELD}",
    // Start one step ahead of the UE's counter, same reasoning as the 5G
    // side: free5gc/Open5GS increment SQN by 1, and any value under 32
    // leaves SEQ at 0, which the UE reads as "not fresh".
    sqn: NumberLong(35)
  },
  ambr: {
    downlink: { value: NumberInt(1), unit: NumberInt(3) },
    uplink:   { value: NumberInt(1), unit: NumberInt(3) }
  },
  // The IMS APN. Its name matches the 5G side's ims DNN so that a reader
  // does not have to hold two vocabularies in their head at once.
  slice: [{
    sst: NumberInt(1),
    default_indicator: true,
    session: [{
      name: "ims",
      type: NumberInt(3),
      qos: { index: NumberInt(5), arp: {
        priority_level: NumberInt(1),
        pre_emption_capability: NumberInt(1),
        pre_emption_vulnerability: NumberInt(1) } },
      ambr: {
        downlink: { value: NumberInt(10), unit: NumberInt(2) },
        uplink:   { value: NumberInt(10), unit: NumberInt(2) }
      }
    }]
  }],
  access_restriction_data: NumberInt(32),
  subscriber_status: NumberInt(0),
  network_access_mode: NumberInt(0),
  subscribed_rau_tau_timer: NumberInt(12),
  __v: NumberInt(0)
});
EOF
done

echo
echo "[ims-sub] subscribers now in the HSS:"
docker exec poc-hss-db mongo --quiet open5gs --eval \
    'db.subscribers.find({}, {imsi:1, msisdn:1, _id:0}).forEach(function(d){ print("  " + d.imsi + "  msisdn=" + d.msisdn); })'
