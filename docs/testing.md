# Testing

Each test is written to fail loudly when the thing it names stops working, and
to avoid claiming more than it has shown. What a test does *not* assert is
stated as deliberately as what it does.

## Scripts

| Script | Purpose |
|---|---|
| `00-setup-gtp5g.sh` | Build and load the user-plane kernel module |
| `01-up.sh` | Bring up the core, the IMS, the RAN, and provision subscribers |
| `02-add-subscribers.sh` | 5G subscription data into the UDR |
| `03-call-test.sh` | Registration, call, media, and QoS — end to end |
| `04-add-ims-subscribers.sh` | IMS identities into the HSS |
| `05-n5-qos-test.sh` | The policy chain on its own, without SIP |
| `99-down.sh` | Tear everything down |

## `03-call-test.sh` — the end-to-end test

Two subscribers register, one calls the other, they exchange G.711, and the
call is released. Four independent claims are checked, because "a call
connected" on its own is weak evidence.

**The call traversed three separate CSCF roles.** Each role logs its own part
of the path, and the test prints the five steps in order: originating INVITE
at the P-CSCF, the I-CSCF's LIR and the answer, the S-CSCF resolving the
public identity to a registered contact, and the terminating INVITE arriving
back at the P-CSCF.

**All four Cx exchanges were used.** UAR and LIR from the I-CSCF, MAR and SAR
from the S-CSCF. Counted per run, not cumulatively.

**The P-CSCF reserved QoS as an Application Function.** The rules exist only
while the call is up, so the kernel's rule set is sampled while SIP is still
in progress. The test reports the dedicated PDRs it found and which QER each
points at.

**Everything travelled over the 5G user plane.** GTP-U is captured on the N3
bridge and the SIP methods are located inside the tunnels, along with the RTP
stream. This is what distinguishes a real path from the container network
underneath it — without it a call could succeed while proving nothing.

The test also refuses to run at all if the UEs did not learn a P-CSCF address
from the network, or if either UE configuration so much as mentions one. A
constant that happens to be correct would make PCO discovery decorative, and a
check that cannot fail is not a check.

## `05-n5-qos-test.sh` — the policy chain alone

Drives the Application Function directly, with no SIP involved, and reads back
what `gtp5g` is matching packets against. It exists so that a failure can be
attributed: if this passes and the end-to-end test does not, the problem is in
the IMS; if this fails, it is in the core.

It asserts one PDR per direction carrying the media five-tuple, both pointing
at a QER with the requested guaranteed bit rate, and that releasing the
session removes them again.

## What is not tested

**QoS enforcement.** Only rule installation. See
[policy-and-qos.md](policy-and-qos.md) for why measuring throughput would be
misleading rather than merely incomplete.

**Scale.** One call between two subscribers. Nothing here says anything about
behaviour under load.

**Preconditions.** The reservation is made when the call is answered, not
negotiated before it is. A real IMS uses SIP preconditions at the provisional
response and holds the call until the network confirms resources; there is no
PRACK handling here.

**Media anchoring.** RTP flows directly between the two devices. Nothing
verifies the flows against what was signalled, because nothing enforces them
either.

**Failure paths.** Registration rejection, call rejection, timer expiry and
re-registration are exercised only incidentally.
