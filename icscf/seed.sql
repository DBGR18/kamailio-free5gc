-- The S-CSCF pool the I-CSCF can choose from.
--
-- Two paths lead here. When the HSS already knows which S-CSCF serves a
-- user, its UAA carries the Server-Name and the I-CSCF uses that directly.
-- When it does not -- a first registration -- the HSS returns capabilities
-- instead, and the I-CSCF picks from this table.
--
-- The URI must match the S-CSCF's own scscf_name, or the REGISTER is
-- forwarded to a name nothing answers to.
INSERT INTO s_cscf (id, name, s_cscf_uri)
VALUES (1, 'scscf.ims.mnc093.mcc208.3gppnetwork.org',
           'sip:scscf.ims.mnc093.mcc208.3gppnetwork.org:6060');

-- Capability 0 is the "mandatory capability" this deployment declares; the
-- HSS returns the same value, and the match is what makes this S-CSCF
-- eligible.
INSERT INTO s_cscf_capabilities (id, id_s_cscf, capability) VALUES (1, 1, 0);

-- Domains whose asserted identities we accept without re-checking. Only our
-- own IMS realm is trusted here.
INSERT INTO nds_trusted_domains (id, trusted_domain)
VALUES (1, 'ims.mnc093.mcc208.3gppnetwork.org');
