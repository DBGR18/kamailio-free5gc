#!/bin/bash
#
# Build and load the gtp5g kernel module.
#
# Why this exists: free5gc's UPF does not forward GTP-U packets in user space.
# It programs a kernel module called gtp5g through Netlink, and that module
# does the actual encapsulation/decapsulation. No gtp5g -> no user plane ->
# the PDU session comes up but no packet ever flows.
#
# gtp5g is out-of-tree, so it must be rebuilt after every kernel upgrade.
# Upstream master handles the Linux 7.x API changes itself (flowi4_dscp and
# sockaddr_unsized are version-gated in its own source), so no local patch is
# needed -- free5gc v4.2.2+ accepts 0.9.5 <= gtp5g < 0.11.0.
#
# The source tree lives OUTSIDE this repo; override with GTP5G_DIR=... .
set -e

GTP5G_DIR="${GTP5G_DIR:-${HOME}/gtp5g}"

if lsmod | grep -q '^gtp5g'; then
    echo "[gtp5g] already loaded:"
    lsmod | grep '^gtp5g'
    exit 0
fi

if [ ! -f "${GTP5G_DIR}/Makefile" ]; then
    echo "[gtp5g] ERROR: no gtp5g tree at ${GTP5G_DIR}"
    echo "[gtp5g] clone https://github.com/free5gc/gtp5g, or set GTP5G_DIR"
    exit 1
fi

if [ ! -d "/lib/modules/$(uname -r)/build" ]; then
    echo "[gtp5g] ERROR: kernel headers missing for $(uname -r)"
    echo "[gtp5g] install them with: sudo apt install linux-headers-$(uname -r)"
    exit 1
fi

echo "[gtp5g] building in ${GTP5G_DIR} for kernel $(uname -r)"
cd "${GTP5G_DIR}"
make clean >/dev/null 2>&1 || true
make -j"$(nproc)"

echo "[gtp5g] loading module"
sudo modprobe udp_tunnel
sudo insmod ./gtp5g.ko

lsmod | grep '^gtp5g'
echo "[gtp5g] ready (version $(cat /sys/module/gtp5g/version))"
