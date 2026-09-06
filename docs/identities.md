# Subscriber identities

One subscriber exists twice: once in the 5G core and once in the IMS. The two
records are separate, they are read by separate procedures, and neither system
ever looks at the other's copy. Keeping them consistent is a provisioning
concern, not a runtime one.

## The PLMN

Everything below is derived from one operator identity:

| | |
|---|---|
| MCC | 208 |
| MNC | 93 |
| IMS home domain | `ims.mnc093.mcc208.3gppnetwork.org` |

The MNC is padded to three digits in the domain name even though the PLMN uses
two. TS 23.003 §13.2 requires this, and getting it wrong produces a realm that
looks right and matches nothing.

## Derivation

A device without an ISIM derives its IMS identities from the IMSI on its USIM,
following TS 23.003 §13.4B. That is what happens here, so a single IMSI
produces everything:

```
IMSI  208930000000001
  │
  ├─ 5G core
  │    SUPI   imsi-208930000000001
  │
  └─ IMS
       IMPI   208930000000001@ims.mnc093.mcc208.3gppnetwork.org
       IMPU   sip:208930000000001@ims.mnc093.mcc208.3gppnetwork.org
```

The **IMPI** is the private identity: it names the credential, and only the
HSS and the S-CSCF ever see it. The **IMPU** is the public identity: it is
what other people dial, and one subscriber may have several.

An MSISDN is provisioned alongside as a dialable number, but nothing in this
project routes on it — calls are placed to the IMPU directly.

## What lives where

| Store | Holds | Used by |
|---|---|---|
| UDR | SUPI, K, OPc, AMF, SQN, slice and DNN subscriptions, session policy | 5G registration and PDU session establishment |
| PyHSS | IMPI, IMPU, MSISDN, realms, K, OPc, AMF, SQN, service profile | IMS registration and call routing |

Both hold key material, and it is the same K and OP — but the two
authentications keep **separate sequence number counters**, because they are
independent procedures. A UE that has registered with the 5G core has not
authenticated with the IMS and must do so again.

## Key material

Milenage, using 3GPP's published test values. The subtlety worth knowing is
which form each consumer wants:

| Consumer | Wants |
|---|---|
| free5gc UDR | OPc |
| free-ran-ue | OPc |
| PyHSS | OPc — its schema has no OP field |
| SIPp | OP — it computes OPc itself |

`OPc = AES-128-ECB_K(OP) XOR OP`, and that only runs one way. Given OPc you
cannot recover OP. So OP is the value of record here and OPc is derived from
it; the reverse arrangement would leave the SIP client with nothing usable.

The scripts keep this in one place and derive the rest, because a mismatch
does not surface as a configuration error. It surfaces much later as an AUTN
MAC failure, which points at authentication rather than at the value that was
actually wrong.

## Authentication

Two independent AKA runs.

**5G-AKA**, between the UE and the AUSF/UDM, during registration. The UE ends
up with a security context and, after PDU session establishment, an IP
address. As far as the IMS is concerned nothing has happened yet.

**IMS AKA** (`AKAv1-MD5`, RFC 3310), between the UE and the S-CSCF, during SIP
registration. The S-CSCF fetches a vector from the HSS over Cx, challenges the
UE with `RAND` and `AUTN` carried in the SIP `nonce`, and verifies the response
before recording the binding.

The sequence numbers drift apart in a lab — a UE re-attaching, a database
reset — and a UE that sees a stale `SQN` answers with `AUTS` rather than
failing. The S-CSCF handles that by asking the HSS to resynchronise instead of
rejecting the registration.
