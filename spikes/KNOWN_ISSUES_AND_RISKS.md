# Known Issues and Risks

Open questions and potential problems identified during design. Revisit before
starting each implementation phase.

---

## Custom ACME Client Complexity

**Issue:** The `AcmeClient` module for custom domain cert issuance is estimated at
~150 lines but realistically closer to 400-500 once account registration, order
creation, authorization fetching, challenge polling, certificate download, key
generation, and error handling are all covered.

**Risk:** Underestimating this is the most likely cause of implementation delays.

**Mitigation:** Before building from scratch, check whether SiteEncrypt exposes any
reusable ACME primitives internally. Also track the DNS-01 SiteEncrypt PR — if it
lands, the custom domain certs can use the same client and this module shrinks
significantly.

---

## ACME Account Key Not Specified

**Issue:** The custom domain cert spec does not mention ACME account key management.
Let's Encrypt requires a keypair to be registered once as an account and reused
across all subsequent cert orders. This keypair must be persisted to disk.

**Risk:** Forgetting this means re-registering a new account on every gateway restart,
which wastes rate limit quota and may trigger abuse detection.

**Fix:** Add account key generation, storage (`certs/acme_account.pem`), and reuse
to the `AcmeClient` spec before implementation starts.

---

## Cert Reload Mechanism

**Issue:** The spec proposes a `USR1` Unix signal to tell the gateway to reload
wildcard certs after acme.sh renews them. This works on Linux but is inconsistent
with the rest of the architecture.

**Better option:** Add `POST /reload-certs` to the internal API and pass it as
acme.sh's `--reloadcmd`. Keeps all operational interfaces going through one place
and works the same way on every OS.

---

## Cluster Sync at Scale

**Issue:** When a secondary node first joins the cluster, the existing
`CertificateManager` RPC syncs certs from the primary. For a small number of
domains this is fine. If writeinone grows to thousands of custom domains, syncing
all cert files on node join could be slow and consume significant bandwidth.

**Risk:** Not a problem now. Becomes a problem at scale.

**Mitigation when needed:** Make the sync incremental — secondary requests only certs
it does not already have by comparing a manifest of `{domain, issued_at}` pairs
rather than transferring all files blindly.

---

## Three Cert Management Systems

**Issue:** The final architecture has three separate cert mechanisms:
- SiteEncrypt — your own domains, HTTP-01, managed by the Phoenix app
- acme.sh — wildcard certs, DNS-01, managed by an external cron job
- AcmeClient — custom user domains, HTTP-01, managed by Elixir

**Risk:** Operational knowledge is spread across three tools. Debugging a cert
failure requires knowing which system owns that domain.

**Mitigation:** Clear documentation of which system owns which cert type. If the
SiteEncrypt DNS-01 PR is accepted, acme.sh can be eliminated and this collapses
to two systems.

---

## CertRenewalScheduler Is Unnecessary as a Separate Process

**Issue:** The spec introduces `CertRenewalScheduler` as its own GenServer. A daily
renewal scan is a single `:timer.send_interval` call that fits inside
`CustomDomainRegistry` without adding another supervised process.

**Fix:** Remove `CertRenewalScheduler` from the supervision tree. Move the renewal
scan into `CustomDomainRegistry` as a scheduled message.

---

## YAML Parser Dependency

**Issue:** `gateway.yaml` requires a YAML parsing library. Elixir's standard library
has no YAML parser. The main option is `yaml_elixir`, which wraps the Erlang
`yamerl` library.

**Risk:** Minor. Adds one dependency. `yamerl` has occasional edge cases with
non-standard YAML.

**Alternative:** If the dependency feels undesirable, the config format can be
switched to JSON — the only real loss is inline comments. The `${VAR}` substitution
and service-oriented structure work identically in JSON.

---

## Let's Encrypt Rate Limits for Custom Domains

**Issue:** Let's Encrypt allows 300 new certificate orders per 3 hours per account.
If writeinone runs a promotion and many users add custom domains simultaneously,
this limit could be hit.

**Current risk:** Low. Only affects paid users with custom domains.

**Mitigation when needed:** Queue cert issuance with a rate-aware scheduler. Show
users a "your certificate is queued" state rather than failing. The 30-day renewal
window means existing certs are never at risk from this limit.
