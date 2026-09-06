# Documentation

These notes describe what this project builds and why it is put together the
way it is. They are about architecture and concepts, not about operating any
particular machine.

## Reading order

| Document | What it covers |
|---|---|
| [architecture.md](architecture.md) | Components, networks, and the interfaces between them |
| [identities.md](identities.md) | How one subscriber becomes a 5G identity and an IMS identity |
| [call-flows.md](call-flows.md) | Registration and call setup, message by message |
| [policy-and-qos.md](policy-and-qos.md) | How a SIP call turns into a QoS rule in the user plane |
| [testing.md](testing.md) | What each test asserts, and what it deliberately does not |

If you are new to the subject, `architecture.md` first, then `call-flows.md`.
If you already know IMS and want to see what is 5G-specific here, start with
`policy-and-qos.md`.

## What this project is

A 5G core gives a device authentication, an IP address, and a tunnel to carry
its packets. It does not give it phone calls. Calls are IMS: a separate system
that speaks SIP, knows who is reachable where, and asks the network for the
treatment a voice stream needs.

This repository runs both, connects them the way 3GPP specifies, and verifies
each connection rather than assuming it. free5gc provides the 5G core,
Kamailio provides the three CSCF roles, PyHSS provides the IMS subscriber
database, and the two halves meet at three places: the user plane (N6), the
policy plane (N5), and the PDU session establishment itself (PCO).

## What it is not

Not a product, and not a performance target. Everything here is sized for one
call between two subscribers, because the interesting question is whether the
interfaces work, not how many of them work at once. Where a shortcut is taken,
the documentation says so.
