#!/bin/bash
#
# Reading the rules gtp5g is actually matching packets against.
#
# This is the only honest place to verify QoS work in this PoC. free5gc
# implements the QoS spec surface but enforces none of it -- no rate limiting,
# no guaranteed bitrate -- so a throughput measurement would say nothing about
# whether the policy chain worked. What can be checked is whether the rule was
# installed, and that lives in the kernel behind gtp5g's own netlink family.

# Resolve a gogtp5g-tunnel binary, building one if needed. Sets TUNNEL_BIN.
# Returns non-zero if none could be obtained; callers decide whether that is
# fatal.
ensure_gtp5g_reader() {
    TUNNEL_BIN="${TUNNEL_BIN:-/tmp/gogtp5g-tunnel}"
    if [ -x "${TUNNEL_BIN}" ]; then
        return 0
    fi
    command -v go >/dev/null 2>&1 || return 1
    echo "[gtp5g] building gogtp5g-tunnel (reads gtp5g's rules from the kernel)"
    GOBIN="$(dirname "${TUNNEL_BIN}")" \
        go install github.com/free5gc/go-gtp5gnl/cmd/gogtp5g-tunnel@latest 2>/dev/null \
        || return 1
    [ -x "${TUNNEL_BIN}" ]
}

# The gtp5g device lives in the UPF container's network namespace, so the tool
# has to run inside it. From the host it reports nothing at all, which looks
# exactly like "no rules installed" -- a silent wrong answer, so this is worth
# keeping in one place.
gtp5g_rules() {
    local kind="$1" pid
    pid=$(docker inspect -f '{{.State.Pid}}' poc-upf 2>/dev/null) || return 1
    [ -n "${pid}" ] || return 1
    sudo nsenter -t "${pid}" -n "${TUNNEL_BIN}" list "${kind}" 2>/dev/null
}
