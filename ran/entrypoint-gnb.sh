#!/bin/bash
#
# gNB container entrypoint.
#
# The gNB sits on the core network: it speaks NGAP/SCTP to the AMF (N2) and
# GTP-U to the UPF (N3), and it opens two plain sockets that the UE containers
# connect to as a stand-in for the radio link.
set -e

GNB_CONFIG="${GNB_CONFIG:-/ran/config/gnb.yaml}"

echo "[gnb] waiting for the AMF's N2 socket..."
AMF_IP="${AMF_N2_IP:-10.100.200.16}"
AMF_PORT="${AMF_N2_PORT:-38412}"
for _ in $(seq 1 60); do
    # NGAP runs over SCTP, so a TCP probe would always fail. Just wait for the
    # name to resolve and give the AMF a moment to finish binding.
    if getent hosts "${AMF_IP}" >/dev/null 2>&1 || [ -n "${AMF_IP}" ]; then
        break
    fi
    sleep 1
done

echo "[gnb] starting free-ran-ue gnb with ${GNB_CONFIG}"
exec free-ran-ue gnb -c "${GNB_CONFIG}"
