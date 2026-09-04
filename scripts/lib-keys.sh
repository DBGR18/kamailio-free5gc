#!/bin/bash
#
# The SIM key material, in one place.
#
# Sourced by the provisioning scripts. Everything is derived from OP rather
# than stated separately, because the four places that need this material do
# not all want the same form:
#
#   free5gc UDR      OPc   (AuthenticationSubscription.opc.opcValue)
#   free-ran-ue      OPc   (authenticationSubscription.encOpcKey)
#   PyHSS AUC        OPc   (its schema has no "op" field at all)
#   SIPp             OP    (aka_OP; src/milenage.c calls ComputeOPc itself)
#
# OPc = AES-128-ECB_K(OP) XOR OP, which only runs one way: given OPc you
# cannot get back to OP. So OP is the source and OPc is computed, instead of
# the other way round -- otherwise SIPp could never be given a usable value.
#
# K and OP are 3GPP's published test material (TS 35.208 test set 1 uses this
# OP), not secrets.

KEY_K="8baf473f2f8fd09487cccbd7097c6862"
KEY_OP="cdc202d5123e20f62b6d676ac72cb318"
KEY_AMF="8000"

# IMS AKA and 5G AKA keep separate SQN counters, so both start one step ahead
# of a UE that begins at zero. Anything below 32 leaves SEQ at 0 and never
# looks fresh; 0x23 puts SEQ at 1.
KEY_SQN_HEX="000000000023"
KEY_SQN_DEC=35

compute_opc() {
    python3 - "$1" "$2" <<'PY'
import sys
from Crypto.Cipher import AES
k, op = bytes.fromhex(sys.argv[1]), bytes.fromhex(sys.argv[2])
enc = AES.new(k, AES.MODE_ECB).encrypt(op)
print(bytes(a ^ b for a, b in zip(enc, op)).hex())
PY
}

KEY_OPC="$(compute_opc "${KEY_K}" "${KEY_OP}")"

if [ -z "${KEY_OPC}" ]; then
    echo "[keys] ERROR: could not compute OPc (is pycryptodome installed?)" >&2
    exit 1
fi

# The UE simulator's config is static YAML and cannot compute anything, so it
# carries the literal OPc. Check it here rather than letting the two drift
# apart silently -- a mismatch shows up much later as "AUTN validation MAC
# mismatch", which points at authentication rather than at the config.
verify_ue_configs() {
    local root="$1" bad=0 f actual
    for f in "${root}"/config/ue-ue*.yaml; do
        [ -f "${f}" ] || continue
        actual=$(grep -oP 'encOpcKey:\s*"\K[0-9a-fA-F]+' "${f}" || true)
        if [ "${actual}" != "${KEY_OPC}" ]; then
            echo "[keys] ERROR: ${f}"
            echo "[keys]   encOpcKey is ${actual:-<missing>}"
            echo "[keys]   expected    ${KEY_OPC}  (= OPc of OP ${KEY_OP})"
            bad=1
        fi
    done
    return "${bad}"
}
