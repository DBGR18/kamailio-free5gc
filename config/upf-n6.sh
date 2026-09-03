#!/bin/bash
#
# UPF data-plane setup for this PoC.
#
# The UPF is dual-homed:
#   corenet (10.100.200.0/24) -- N3 towards the gNB, N4 towards the SMF
#   dnnet   (10.100.100.0/24) -- N6 towards the Data Network (where the IMS lives)
#
# UE traffic (10.60.0.0/16) must reach Kamailio with its ORIGINAL source IP,
# otherwise both UEs would appear to the SIP proxy as the same NAT address and
# SIP routing would need NAT helpers. So we deliberately do NOT masquerade
# towards the DN; we only masquerade what leaves through the core network
# interface (i.e. traffic heading for the outside world).
#
set -e

# Resolve interface names from their subnets: Docker does not guarantee that
# the first network in the compose file becomes eth0.
CORE_IF=$(ip -o -4 addr show | awk '$4 ~ /^10\.100\.200\./ {print $2; exit}')
DN_IF=$(ip -o -4 addr show   | awk '$4 ~ /^10\.100\.100\./ {print $2; exit}')

echo "[upf-n6] core interface (N3/N4): ${CORE_IF:-<none>}"
echo "[upf-n6] DN interface   (N6)   : ${DN_IF:-<none>}"

iptables -I FORWARD 1 -j ACCEPT

if [ -n "$CORE_IF" ]; then
    # Internet-bound UE traffic still needs NAT.
    iptables -t nat -A POSTROUTING -o "$CORE_IF" -j MASQUERADE
fi

# No MASQUERADE rule for $DN_IF on purpose: Kamailio sees the real UE IPs.
exit 0
