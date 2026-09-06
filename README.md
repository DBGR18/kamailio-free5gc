# kamailio-free5gc

Running an IMS on top of a 5G core, built up one verified step at a time.

## Goal

5G gives you authentication, an IP address, and a data tunnel. It does not give
you phone calls. Calls are IMS: a separate system that speaks SIP and decides
who is ringing whom.

This repository connects the two:

- **free5gc** — the 5G core (registration, PDU sessions, user-plane forwarding)
- **Kamailio** — the IMS side (SIP registration and call routing)
- They meet at **N6**, the interface where the UPF hands traffic to an external
  network. To the 5G core, IMS is just a server sitting out on a data network.

The point is that this connection is *real*. The two sides live on separate
Docker networks, so a UE can only reach Kamailio by going through the UPF —
there is no shortcut path, and no NAT hiding who sent what.

## Where this is going

Today Kamailio is a general-purpose SIP proxy that happens to look like an IMS.
Turning it into an actual IMS means:

1. **A dedicated `ims` DNN** so IMS traffic rides its own PDU session
2. **An HSS** — a real identity source, so registration is authenticated
   instead of trusted
3. **Splitting P-CSCF / I-CSCF / S-CSCF** into their proper roles
4. **N5 toward the PCF** so voice gets its own QoS treatment
5. **P-CSCF discovery via PCO** instead of a hardcoded address

Each step is ordered so that the one before it becomes verifiable.

## Quick start

```bash
./scripts/00-setup-gtp5g.sh   # build + load the kernel module
./scripts/01-up.sh            # core network, IMS, and subscribers
./scripts/99-down.sh          # tear everything down
```

Requirements: Docker with Compose, `linux-headers` matching the running kernel,
and passwordless `sudo` (loading a kernel module needs it).

**gtp5g is not vendored here.** It is an out-of-tree kernel module and has to be
rebuilt after every kernel upgrade. The scripts expect a checkout at `~/gtp5g`
on `master`; set `GTP5G_DIR` if yours lives elsewhere.

## Layout

| Path | What it is |
|---|---|
| `docker-compose.yaml` | The whole topology: two networks, one UPF bridging them |
| `config/` | free5gc network function configs |
| `pcscf/`, `icscf/`, `scscf/` | The three CSCF roles |
| `hss/` | PyHSS configuration |
| `scripts/` | Bring-up, provisioning, teardown |

`docs/` explains the architecture and the concepts behind it: how the two halves
connect, how a subscriber exists in both, what happens during registration and a
call, and how a SIP session becomes a QoS rule in the user plane.

## Versions

| Component | Version | Note |
|---|---|---|
| free5gc | v4.2.3 | Docker images |
| gtp5g | master (0.10.2) | Host kernel module, builds clean on Linux 7.x |
| Kamailio | 6.x | Built from the Debian package |
