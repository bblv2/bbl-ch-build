# Per-host overrides (non-secret)

One file per host, named `<short>.conf` (the hostname without the
`.bblapp.io` suffix). Read by `scripts/provision.sh` *after*
`seeds/defaults.conf` to encode known fleet-level routing decisions
(which DB cluster, which role, etc.) that diverge from defaults.

Rules:
- Only **non-secret** values. Per-host secret overrides (e.g. the
  bbl26-cluster Django secret key) live in
  `/etc/bbl-ch-secrets.d/<short>.conf` on rpt.
- Hosts that exactly match `defaults.conf` do not need a file here.
- `BBL_DOMAIN` is auto-set by `provision.sh` from the `hostname=`
  argument — do not duplicate it in this file.

Current fleet snapshot at the time this directory was introduced:

| Short host    | DB host                | DB name        | Other          |
|---------------|------------------------|----------------|----------------|
| ch-atl5/6/7   | lb-atl                 | bbl26          | (sec override) |
| ch-atl8       | lb-atl                 | nodebblclean   | role=beta      |
| ch-atl11-14   | lb-atl                 | nodebblclean   |                |
| ch-atl20-22   | lb-atl                 | nodebblclean   |                |
| ch-atl23/24   | (defaults)             | (defaults)     |                |
| chb-atl15-19  | lb-atl                 | nodebblclean   |                |
| ch1-test      | lb-atl                 | bbl26          | (sec override) |
| ch-test-2     | lb-atl                 | bbl26          | (sec override) |
