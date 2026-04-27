# Gateway Config, SSL, and Custom Domains

## Overview

This document covers three related changes:

1. **`gateway.yaml`** ✅ — a service-oriented config file that replaces the current flat
   environment variables (`GATEWAY_SERVICES`, `LETSENCRYPT_DOMAINS`, `DDNS_DOMAINS`).
2. **Per-domain SSL with certbot** — how all domains (owned and custom) get per-domain
   certs via certbot. HTTP-01 (webroot) for regular domains; DNS-01 (Cloudflare plugin)
   for wildcard certs. One tool, one cert directory tree.
3. **Custom domains for multi-tenant services** — how a service like writeinone.com can
   accept user-owned domains, obtain per-domain SSL certs automatically via certbot, and
   route traffic correctly.

---

## ~~1. `gateway.yaml`~~ ✅ DONE

> **Status: DONE** — `gateway.yaml` loader is fully implemented. The file is gitignored
> (contains DDNS tokens inline; production deployments use `${ENV_VAR}` substitution).
> The flat env var fallback (`GATEWAY_SERVICES`, `LETSENCRYPT_DOMAINS`, `DDNS_DOMAINS`)
> remains for backwards compatibility.

The `gateway.yaml` schema, field reference, secret substitution, and env var fallback
behaviour are as originally specified. `ElixirGateway.ConfigLoader` reads the file at
startup, performs `${}` substitution, and populates Application env for routing, SSL
domain list, and DDNS config.

~~### What needs to be built~~

~~- `ElixirGateway.ConfigLoader` — reads and parses `gateway.yaml` at startup, performs~~
~~  `${}` substitution, produces the same internal config maps that `runtime.exs` currently~~
~~  builds from env vars.~~
~~- Updates to `runtime.exs` — `GATEWAY_SERVICES`, `LETSENCRYPT_DOMAINS`, `DDNS_DOMAINS`~~
~~  env vars continue to work as before. If `GATEWAY_CONFIG_FILE` is set, the file takes~~
~~  precedence and the flat env vars are ignored. This allows a gradual migration.~~
~~- Updates to `DomainRouter` — read static routes from `ConfigLoader` instead of directly~~
~~  from `Application.get_env`.~~

---

## 2. Per-Domain SSL with Certbot

### Why per-domain certs

The previous approach used SiteEncrypt to issue a single multi-SAN certificate covering
all owned domains. This has two problems:

- The CN (Common Name) is the first domain in the list. Visiting `en2fe.com` shows
  `day-20.com` in the padlock because `day-20.com` happens to come first.
- Adding or removing a domain requires re-issuing the entire cert, which risks hitting
  Let's Encrypt rate limits.

**SiteEncrypt is removed entirely.** Every domain — owned or custom — gets its own
certificate managed by certbot. No custom ACME client is built.

### Certbot in Docker

Certbot is installed in the Docker image alongside the Elixir release. The Elixir app
calls certbot via `System.cmd/3` from `CertbotRunner`, so certbot must be present in
the container filesystem. No external tooling is needed on the host. Renewal is triggered
by a Quantum job inside the Elixir application.

> **Image size note:** Adding certbot (Python + dependencies) adds ~100MB to the image.
> This is an accepted tradeoff.

**Challenge type: HTTP-01 with webroot**

The gateway serves `/.well-known/acme-challenge/` from a local directory. Certbot is
invoked with `--webroot --webroot-path /tmp/acme-webroot`.

> **Critical:** The webroot plug must be added to the router **before** `DomainRouter`.
> If it comes after, challenge requests are forwarded to the backend service which cannot
> serve them — ACME validation fails silently with no obvious error.

**Cert reload after renewal**

`CertbotRunner` calls `CertStore.reload()` directly after certbot exits successfully.
No Unix signals are used. Signals are not needed because certbot is always invoked by
the Elixir process itself, so the reload can be a direct function call.

**Renewal flow (owned domains):**

```
Quantum job fires (daily, primary node only)
  → for each owned domain in gateway.yaml where ssl: true:
      CertbotRunner.ensure_cert(domain)
        → certbot certonly --webroot --webroot-path /tmp/acme-webroot \
            --cert-name <domain> --domain <domain> \
            --non-interactive --agree-tos --email <LETSENCRYPT_EMAIL>
        → certbot skips if cert expires in more than 30 days (built-in)
        → on renewal: CertStore.reload()
```

**Primary node only.** Certbot runs only on the primary node (`IS_PRIMARY != false`).
After renewal, `CertificateManager` syncs updated cert files to secondary nodes via the
existing RPC mechanism, extended to handle the `certs/certbot/live/` directory.

### Why wildcard certs for writeinone.com

A wildcard cert for `*.writeinone.com` covers every subdomain with a single cert renewed
once per 90 days, regardless of how many users have a `username.writeinone.com` subdomain.
Without it, each subdomain would need its own cert.

### Why HTTP-01 is not enough for wildcards

Let's Encrypt only issues wildcard certs via DNS-01 challenge. The gateway must prove it
controls the domain by creating a `_acme-challenge.writeinone.com` TXT record. This
requires programmatic access to the domain's DNS provider.

### Why Cloudflare for writeinone.com

The existing Namecheap DDNS API only updates A records — it cannot create TXT records
needed for DNS-01. The full Namecheap DNS API can, but it requires the calling IP to be
whitelisted, which is incompatible with a dynamic home IP.

Cloudflare's DNS API has no IP restrictions and is supported by `certbot-dns-cloudflare`.

**Existing domains** (seveneat.com, en2fe.com, day-20.com, etc.) stay on Namecheap and
use HTTP-01 certs via certbot webroot.

**writeinone.com** moves to Cloudflare registrar. This is the only domain needing a
wildcard cert right now.

**Future domains** are purchased directly through Cloudflare.

### Cert issuance for wildcard domains

Wildcard certs are issued by certbot using the `certbot-dns-cloudflare` plugin (installed
in the Docker image). The Cloudflare API token is provided via a credentials file mounted
into the container. Certbot is called by the same `CertbotRunner` used for HTTP-01 certs,
just with `--dns-cloudflare` instead of `--webroot`.

```bash
certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /app/certbot/cloudflare.ini \
  --config-dir /app/certbot/config \
  --work-dir /app/certbot/work \
  --logs-dir /app/certbot/logs \
  -d writeinone.com \
  -d "*.writeinone.com" \
  --cert-name writeinone.com \
  --non-interactive --agree-tos --email <LETSENCRYPT_EMAIL>
```

The cert lands in `/app/certbot/config/live/writeinone.com/` alongside all other certbot
certs. No separate tool, no separate directory, no separate reload mechanism.

### Cert storage layout

```
/app/certbot/config/live/     ← certbot manages everything (HTTP-01 + DNS-01)
  seveneat.com/
    fullchain.pem
    privkey.pem
  en2fe.com/  ...
  day-20.com/ ...
  writeinone.com/             ← wildcard cert (covers *.writeinone.com + writeinone.com)
    fullchain.pem
    privkey.pem
  blog.johndoe.com/           ← custom domain, same layout
    fullchain.pem
    privkey.pem

priv/dev_certs/               ← pre-generated self-signed, committed to repo
  cert.pem
  key.pem
```

### Dev and test environment

Dev and test use pre-generated self-signed certificates stored in `priv/dev_certs/` and
committed to the repository. These certs are self-signed and will show a browser warning,
which is acceptable for local development. `CertStore` loads them in `:dev` and `:test`
env as the fallback cert. No internal ACME server is needed.

Generate once with:
```bash
mix phx.gen.cert   # or openssl req -x509 -newkey rsa:4096 ...
```

### SNI callback

Bandit supports a custom SNI callback consulted on every TLS handshake before any HTTP
is read. The gateway registers a callback that checks ETS in order:

```
Client TLS ClientHello with SNI: "blog.writeinone.com"
  1. Exact lookup: "blog.writeinone.com" → not found
  2. Wildcard lookup: strip first label → "*.writeinone.com" → found (writeinone.com cert)
  3. Fall back to dev self-signed cert (dev/test only) or :undefined (production)
```

`CertStore` builds the ETS index by reading the SANs from each cert on disk. A cert
covering `writeinone.com` + `*.writeinone.com` produces two ETS entries, so wildcard
matching is just a second ETS lookup — no regex or glob logic needed.

### DDNS with Cloudflare

The existing `ElixirGateway.Cluster.DDNS.Namecheap` module is joined by a new
`ElixirGateway.Cluster.DDNS.Cloudflare` module. Both implement the same behaviour:
`update_all(domains, ip)`.

The DDNS updater reads the provider from each service's `ddns.provider` field in
`gateway.yaml` and dispatches to the correct module.

### What needs to be built

| Component | Notes |
|---|---|
| Remove `SiteEncrypt` | Delete `ElixirGateway.SiteEncrypt`, strip from endpoint and supervision tree, remove `site_encrypt` dep. Hard cutover. Pre-issue all certbot certs before deploying. |
| `ElixirGateway.CertStore` | GenServer + ETS. Scans `/app/certbot/config/live/` at startup, indexes by SANs (including wildcards). SNI callback does ETS lookup. Reloads on `CertStore.reload()`. In dev/test, falls back to `priv/dev_certs/`. |
| Webroot plug | Serves `/.well-known/acme-challenge/` from `/app/certbot/webroot`. Added to router **before** `DomainRouter`. |
| `ElixirGateway.CertbotRunner` | Wraps certbot CLI via `System.cmd` in a Task. Serialized queue (certbot lock file). Used for HTTP-01 (webroot) and DNS-01 (Cloudflare plugin). Calls `CertStore.reload()` on success. |
| Renewal GenServer | `Process.send_after` loop on primary node only. Calls `CertbotRunner.ensure_cert/1` for each `ssl: true` domain in `gateway.yaml`. No Quantum dependency. |
| Dev self-signed certs | Generated once, committed to `priv/dev_certs/`. |
| SNI callback wiring | Register in endpoint `https` config via Bandit `transport_options`. |
| `CertificateManager` extension | After certbot renewal, sync `/app/certbot/config/live/` to secondaries via existing RPC. Covers owned and custom domains uniformly. |
| `ElixirGateway.Cluster.DDNS.Cloudflare` | Cloudflare DNS A record updater. |

---

## 3. Custom Domains for Multi-Tenant Services (writeinone)

### Overview

writeinone.com allows users to point their own domain (e.g. `blog.johndoe.com`) at the
gateway via a CNAME record. The gateway must:

1. Accept and route requests for that domain to the writeinone service.
2. Obtain and renew an SSL cert for that domain automatically via certbot.
3. Report cert status back to writeinone so the user can be told whether their domain is
   active.

This is a runtime-only, API-driven feature. User domains never appear in `gateway.yaml`.
Cert issuance uses the same `CertbotRunner` as owned domains — no separate ACME client.

### Registration flow

```
User types "blog.johndoe.com" in writeinone dashboard
  → writeinone backend calls gateway internal API:
    POST http://gateway-internal:4001/custom-domains
    { "domain": "blog.johndoe.com", "service": "writeinone" }

Gateway:
  1. Validates domain format.
  2. Adds domain to CustomDomainRegistry immediately.
     → HTTP requests for blog.johndoe.com now route to writeinone target.
     → cert_state: "pending"
     → persists to custom_domains.json
  3. Async: calls CertbotRunner.issue("blog.johndoe.com")
     → certbot certonly --webroot --webroot-path /tmp/acme-webroot -d blog.johndoe.com
     → takes ~30–60 seconds
     → Let's Encrypt validates: user's CNAME → gateway → webroot → LE satisfied.
  4. On success:
     → cert written to certs/certbot/live/blog.johndoe.com/
     → CertbotRunner calls CertStore.reload()
     → cert_state: "issued"
     → SNI callback now returns this cert for blog.johndoe.com.
```

Between steps 2 and 4, HTTP works immediately but HTTPS is not yet available.
writeinone should poll cert status and show the user a "setting up HTTPS" state.

> **Latency note:** Certbot takes 30–60 seconds per issuance. This is acceptable for the
> custom domain flow since it's a one-time async operation. The user sees a "pending" state
> during this window.

### DNS propagation delay

Users frequently register a domain before updating their DNS. If the CNAME is not yet
pointing to the gateway, the certbot HTTP-01 challenge will fail.

The gateway handles this with a retry scheduler:
- Retry every 5 minutes for the first hour.
- Retry every hour after that.
- writeinone can poll `GET /custom-domains/blog.johndoe.com` to get current `cert_state`
  and surface the correct message to the user.

### Persistence

`custom_domains.json` is written atomically (write to `.tmp` then rename) after every
state change.

```json
{
  "blog.johndoe.com": {
    "service": "writeinone",
    "cert_state": "issued",
    "issued_at": "2026-03-24T10:00:00Z",
    "expires_at": "2026-06-22T10:00:00Z"
  },
  "journal.alice.io": {
    "service": "writeinone",
    "cert_state": "pending",
    "registered_at": "2026-03-24T11:00:00Z"
  }
}
```

On gateway restart, domains with `cert_state: "issued"` have their certs loaded from
disk by `CertStore`. Domains with `cert_state: "pending"` resume their retry schedule.

### Cert renewal

The same Quantum daily job that renews owned domains also scans `custom_domains.json`
for certs expiring within 30 days and calls `CertbotRunner.ensure_cert/1` for each.
No separate renewal scheduler process is needed.

### Routing

`DomainRouter` lookup order for an incoming request:

```
1. Dynamic service registry (dynamic_services.json)
2. Custom domain registry (custom_domains.json)
   → match: look up service name → find target in gateway.yaml or dynamic registry
   → forward with original Host header preserved
3. Static config (gateway.yaml)
4. Default service
```

### Rate limits

Let's Encrypt allows 300 new certificate orders per 3 hours per account. For a small
number of paid users with custom domains this is not a concern. If writeinone grows to
where this becomes a limit, queue cert issuance with a rate-aware scheduler and show
users a "certificate queued" state.

### Internal API endpoints (additions to existing internal server)

```
POST /custom-domains
  Body: { "domain": "blog.johndoe.com", "service": "writeinone" }
  Response 200: { "domain": "...", "cert_state": "pending" }
  Response 422: validation error

GET /custom-domains/:domain
  Response 200: { "domain": "...", "cert_state": "pending|issued|failed", "expires_at": "..." }
  Response 404: domain not registered

DELETE /custom-domains/:domain
  Removes domain from registry, deletes cert files, reloads CertStore.
  Response 200: ok
```

### Cluster behaviour

Cert files under `certs/certbot/live/` are synced to secondary nodes via
`CertificateManager`, which covers both owned and custom domain certs uniformly —
no distinction needed since they live in the same directory tree.

### What needs to be built

| Component | Notes |
|---|---|
| `ElixirGateway.CustomDomainRegistry` | GenServer + ETS. Cert state tracking. Renewal scan built in (no separate scheduler process). |
| `/custom-domains` internal API routes | Additions to `InternalController`. |
| `DomainRouter` update | Add custom domain lookup between dynamic registry and static config. |
| Quantum job extension | Extend the daily certbot renewal job to also scan `custom_domains.json`. |
| `CertificateManager` extension | `certs/certbot/live/` covers both owned and custom domains — sync the whole directory tree. |

---

## Implementation Order

1. ~~`gateway.yaml` loader + migration from env vars~~ ✅ **DONE**
2. ~~**Remove SiteEncrypt**~~ ✅ **DONE** — deleted `ElixirGateway.SiteEncrypt`, stripped
   from endpoint and supervision tree, removed `site_encrypt` dep. Dev self-signed cert
   generated at `priv/certs/`.
3. ~~**`CertStore` + SNI callback**~~ ✅ **DONE** — ETS cert store, reads SANs from cert
   files, wildcard lookup, SNI wired via `thousand_island_options` in Bandit config.
4. ~~**Webroot plug + `CertbotRunner` + renewal job**~~ ✅ **DONE** — `AcmeChallengePlug`
   in router (bypasses BotBlocker/RateLimiter), `CertbotRunner` serial queue with Task,
   daily Quantum job checks expiry before queuing. `CertificateManager` updated to sync
   `/app/certbot/config/live/` to secondaries and call `CertStore.reload()` on receipt.
5. **Cloudflare DDNS module** — small, needed once writeinone.com moves to Cloudflare.
6. **Wildcard cert setup** — operational step: run certbot with `--dns-cloudflare` for
   `*.writeinone.com`. Cert lands in same `live/` directory, CertStore picks it up on
   next reload.
7. **`CustomDomainRegistry`** — runtime custom domain registration, calls `CertbotRunner`
   for cert issuance. Extend Quantum renewal job to also scan custom domains expiring
   within 30 days. See `DYNAMIC_SERVICES_LOW_LEVEL.md` for full spec.
