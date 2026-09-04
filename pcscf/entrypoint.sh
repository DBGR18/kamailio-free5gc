#!/bin/bash
#
# Kamailio container entrypoint.
#
# Kamailio lives on the Data Network (N6) side. The UE address pool
# (the IMS DNN pool) is not on any of its local links -- it lives behind the UPF --
# so we install a static route towards the UPF before starting the proxy.
# Without it, SIP replies and RTP would follow the container's default route
# and never reach the UE.
set -e

UPF_DN_IP="${UPF_DN_IP:-10.100.100.30}"
UE_SUBNET="${UE_SUBNET:-10.62.0.0/16}"

echo "[pcscf] routing ${UE_SUBNET} via UPF at ${UPF_DN_IP}"
ip route replace "${UE_SUBNET}" via "${UPF_DN_IP}"
ip route show

exec kamailio -DD -E -f /etc/kamailio/kamailio.cfg
