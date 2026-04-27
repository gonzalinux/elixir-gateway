# Known Issues and Risks

Open questions and potential problems identified during design. Revisit before
starting each implementation phase.

---

## ~~Custom ACME Client Complexity~~ ✅ RESOLVED

~~**Issue:** The `AcmeClient` module for custom domain cert issuance is estimated at~~
~~~150 lines but realistically closer to 400-500 once account registration, order~~
~~creation, authorization fetching, challenge polling, certificate download, key~~
~~generation, and error handling are all covered.~~

**Resolution:** No custom ACME client is built. Certbot handles all cert issuance —
both owned domains (via Quantum job) and custom user domains (via `CertbotRunner`
called from `CustomDomainRegistry`). Account key management, order lifecycle, and
error handling are all delegated to certbot.

---

## ~~ACME Account Key Not Specified~~ ✅ RESOLVED

~~**Issue:** The custom domain cert spec does not mention ACME account key management.~~
~~Let's Encrypt requires a keypair to be registered once as an account and reused~~
~~across all subsequent cert orders.~~

**Resolution:** Certbot manages the account key automatically under its own data
directory. No Elixir-side key management is needed.

---

## ~~Cert Reload Mechanism~~ ✅ RESOLVED

~~**Issue:** The spec proposed a `USR1` Unix signal to tell the gateway to reload~~
~~wildcard certs after acme.sh renews them.~~

**Resolution:** No Unix signals are used.
- **Certbot** (owned + custom domains): `CertbotRunner` calls `CertStore.reload()`
  directly after `System.cmd` returns — no signal needed.
- **acme.sh** (wildcard cert): uses `--reloadcmd "curl -s -X POST http://localhost:4001/reload-certs"`,
  calling the gateway's internal API. Consistent with how all other operational
  interfaces work.

---

## ~~Three Cert Management Systems~~ → Two Systems

~~**Issue:** The final architecture has three separate cert mechanisms:~~
~~- SiteEncrypt — your own domains, HTTP-01, managed by the Phoenix app~~
~~- acme.sh — wildcard certs, DNS-01, managed by an external cron job~~
~~- AcmeClient — custom user domains, HTTP-01, managed by Elixir~~

**Current state:** Two systems remain, with a clear ownership boundary:
- **certbot** — all HTTP-01 certs (owned domains + custom user domains). Invoked by
  Elixir via `CertbotRunner`. One tool, one cert directory tree.
- **acme.sh** — wildcard cert for `*.writeinone.com` only (DNS-01 via Cloudflare).
  Required because HTTP-01 cannot issue wildcards. If a future Let's Encrypt client
  supports DNS-01 natively in Elixir, acme.sh can be eliminated.

---

## ~~CertRenewalScheduler Is Unnecessary as a Separate Process~~ ✅ RESOLVED

~~**Issue:** The spec introduces `CertRenewalScheduler` as its own GenServer.~~

**Resolution:** No separate `CertRenewalScheduler` process. The Quantum daily job
handles renewal for both owned domains (from `gateway.yaml`) and custom domains
(from `custom_domains.json`) in a single pass. `CustomDomainRegistry` handles
retry scheduling for pending certs internally.

---

## ~~YAML Parser Dependency~~ ✅ RESOLVED

~~**Issue:** `gateway.yaml` requires a YAML parsing library (`yaml_elixir`).~~

**Resolution:** `yaml_elixir` is already added and in use by `ConfigLoader`.

---

## Certbot Latency for Custom Domain Issuance

**Issue:** Certbot takes ~30–60 seconds per cert issuance. For owned domains (renewed
daily by a background job) this is invisible to users. For custom domain registration,
the user sees a "pending" state for up to 60 seconds before HTTPS becomes available.

**Current risk:** Acceptable. The registration flow is async and writeinone is expected
to poll `GET /custom-domains/:domain` and surface an appropriate UI state.

**Mitigation if needed:** Show a progress indicator in the writeinone UI. The 30–60s
window is comparable to other "DNS propagation" UX patterns users are familiar with.

---

## Certbot Docker Image Size

**Issue:** Adding certbot (Python + dependencies) to the Elixir Docker image adds
approximately 100MB.

**Current risk:** Accepted tradeoff. Certbot must be in the container because
`CertbotRunner` calls it via `System.cmd`. A sidecar container approach would avoid
the size increase but adds orchestration complexity that is not justified at current scale.

---

## Webroot Plug Must Precede DomainRouter

**Issue:** ACME HTTP-01 challenges arrive as normal HTTP requests on port 80 for
`/.well-known/acme-challenge/<token>`. If the webroot plug is inserted after
`DomainRouter` in the pipeline, challenge requests are forwarded to backend services
which cannot serve them — certbot fails with a generic validation error and no obvious
log message explains why.

**Fix:** The webroot plug must be the first plug in the pipeline that can return a
response, before `BotBlocker`, `RateLimiter`, and `DomainRouter`. Document this as a
hard constraint in the implementation checklist.

---

## CertStore Must Start Before Endpoint

**Issue:** If the Phoenix Endpoint starts listening on port 443 before `CertStore`
has loaded certs and registered the SNI callback, there is a startup window where TLS
handshakes fail or return the wrong cert.

**Fix:** `CertStore` is position 2 in the supervision tree, immediately after
`ConfigLoader` and before all other children including `Endpoint`. This is documented
in the supervision order in `DYNAMIC_SERVICES_LOW_LEVEL.md`.

---

## Cluster Sync at Scale

**Issue:** When a secondary node first joins the cluster, `CertificateManager` syncs
certs from the primary. For a small number of domains this is fine. If writeinone grows
to thousands of custom domains, syncing all cert files on node join could be slow.

**Current risk:** Not a problem now.

**Mitigation when needed:** Make sync incremental — secondary requests only certs it
does not already have by comparing a manifest of `{domain, issued_at}` pairs rather
than transferring all files blindly.

---

## Certbot Concurrency — Serial Queue Required

**Issue:** Certbot uses a lock file (`/var/lib/letsencrypt/.certbot.lock`). If two custom
domains are registered simultaneously and both trigger `CertbotRunner`, the second
invocation fails immediately with a lock error, leaving that domain stuck in
`cert_state: "pending"` until the next retry.

**Fix:** `CertbotRunner` must serialize all certbot invocations through a single queue.
A GenServer that processes one issuance at a time is sufficient. Callers cast a request
and receive a callback (or poll `CustomDomainRegistry`) for the result. The queue also
naturally handles the retry scheduler — pending domains are re-queued without risk of
concurrent runs.

---

## `System.cmd` Must Not Block a GenServer

**Issue:** `System.cmd("certbot", ...)` blocks for 30–60 seconds. If this is called
inside a GenServer's `handle_cast` or `handle_call`, that GenServer is frozen for the
entire duration — all other messages queue up and timeouts can cascade.

**Fix:** `CertbotRunner` must spawn a `Task` (or use `Task.Supervisor`) for each certbot
invocation. The GenServer dispatches the work and remains responsive. The Task sends a
message back on completion to update `CustomDomainRegistry` cert state and call
`CertStore.reload()`.

---

## Webroot Plug Must Be Before RateLimiter and BotBlocker

**Issue:** The spike states the webroot plug must be before `DomainRouter`, but
Let's Encrypt validation requests look like ordinary HTTP traffic. `BotBlocker` could
classify them as bots; `RateLimiter` could throttle them. Either would cause silent
ACME validation failures — certbot reports a generic HTTP error with no indication
that the gateway itself rejected the challenge.

**Fix:** The webroot plug must be the first plug in the pipeline capable of returning
a response — before `BotBlocker`, `RateLimiter`, `WebSocketUpgradePlug`, and
`DomainRouter`. It matches only `/.well-known/acme-challenge/*` and passes everything
else through, so there is no security or performance impact.

---

## Wildcard Routing Patterns vs HTTP-01 Cert Coverage

**Issue:** `gateway.yaml` declares routing patterns like `*.seveneat.com` and
`*.en2fe.com`. Certbot HTTP-01 cannot issue wildcard certs, so no cert exists for
`sub.seveneat.com`. A TLS request to any subdomain of a Namecheap-managed domain will
fail the SNI lookup in `CertStore` and the TLS handshake will fail.

**Current risk:** Low — those wildcard routing patterns exist to catch subdomains for
routing purposes and nothing currently uses them over HTTPS. But it should be
explicitly acknowledged so it is not mistaken for a bug when encountered.

**Accepted limitation:** Wildcard HTTPS is only available for Cloudflare-managed domains
(DNS-01 via acme.sh). Namecheap domains get a cert for the root domain only. Subdomain
HTTPS on Namecheap domains requires either moving to Cloudflare or registering each
subdomain as a custom domain.

---

## Quantum vs Simple Timer for Renewal Job

**Issue:** The plan references Quantum for the daily certbot renewal job, but Quantum
is not yet a dependency. For a single recurring job, Quantum adds a dependency that
is not justified — `:timer.send_interval` inside a GenServer or a `Process.send_after`
loop achieves the same result with zero new dependencies.

**Quantum is worth adding if:** multiple scheduled jobs exist with different cadences,
cron expression configuration is needed, or job execution needs to survive node
restarts with persistent scheduling. None of these apply to the renewal job today.

**Fix:** Implement the renewal job as a plain GenServer with `Process.send_after`.
Revisit Quantum if the number of scheduled jobs grows or cron-style configuration is
needed.

---

## Let's Encrypt Rate Limits for Custom Domains

**Issue:** Let's Encrypt allows 300 new certificate orders per 3 hours per account.
If writeinone runs a promotion and many users add custom domains simultaneously, this
limit could be hit.

**Current risk:** Low. Only affects paid users with custom domains.

**Mitigation when needed:** Queue cert issuance with a rate-aware scheduler. Show
users a "your certificate is queued" state rather than failing.
