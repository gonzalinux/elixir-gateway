# Gateway Config, SSL, and Custom Domains

## Overview

This document covers three related changes:

1. **`gateway.yaml`** — a service-oriented config file that replaces the current flat
   environment variables (`GATEWAY_SERVICES`, `LETSENCRYPT_DOMAINS`, `DDNS_DOMAINS`).
2. **Wildcard SSL and Cloudflare integration** — how wildcard certs are obtained for
   domains managed through Cloudflare, and why Cloudflare is the target registrar for
   future domains.
3. **Custom domains for multi-tenant services** — how a service like writeinone.com can
   accept user-owned domains, obtain per-domain SSL certs automatically, and route
   traffic correctly.

These three pieces interact: `gateway.yaml` declares which DDNS provider a service uses,
the DDNS provider determines how wildcard certs are obtained, and the custom domain system
builds on top of the same cert and routing infrastructure.

---

## 1. `gateway.yaml`

### Motivation

The current `.env` file repeats the same domain names across three separate variables:

```bash
LETSENCRYPT_DOMAINS="seveneat.com,en2fe.com,writeinone.com,..."
GATEWAY_SERVICES="*seveneat.com=>http://192.168.2.160:8443;*en2fe.com=>http://192.168.2.151:4000;..."
DDNS_DOMAINS="@:seveneat.com:token1,@:en2fe.com:token2,..."
```

Adding or removing a service requires editing three separate strings. `gateway.yaml`
makes the service the top-level entity so each service is declared once.

### File location

`gateway.yaml` lives outside the release directory so it survives deployments:

```
/etc/elixir_gateway/gateway.yaml   # recommended for production
priv/gateway.yaml                  # fallback if env var not set
```

Configurable via `GATEWAY_CONFIG_FILE` env var.

### Schema

```yaml
services:

  # -- example: existing Namecheap-managed domain --
  seveneat:
    target: http://192.168.2.160:8443
    domains:
      - "*.seveneat.com"
      - seveneat.com
    ssl: true
    ddns:
      provider: namecheap
      record: "@"
      domain: seveneat.com
      token: "${SEVENEAT_DDNS_TOKEN}"

  en2fe:
    target: http://192.168.2.151:4000
    domains:
      - "*.en2fe.com"
      - en2fe.com
    ssl: true
    ddns:
      provider: namecheap
      record: "@"
      domain: en2fe.com
      token: "${EN2FE_DDNS_TOKEN}"

  # -- example: Cloudflare-managed domain --
  writeinone:
    target: http://192.168.2.151:4000
    domains:
      - "*.writeinone.com"
      - writeinone.com
    ssl:
      enabled: true
      wildcard: true          # triggers DNS-01 challenge instead of HTTP-01
    ddns:
      provider: cloudflare
      zone_id: "${WRITEINONE_CF_ZONE_ID}"
      token: "${CF_API_TOKEN}"

  # -- example: SSL only, no DDNS needed --
  gonzalo_blog:
    target: http://192.168.2.151:4000
    domains:
      - blog.gonzalo-leon.site
    ssl: true

  # -- catch-all --
  default:
    target: http://192.168.2.151:4000
    domains:
      - default
    ssl: false
```

### Field reference

| Field | Required | Description |
|---|---|---|
| `target` | yes | Base URL to forward matching requests to |
| `domains` | yes | List of domain patterns for routing. Glob patterns (`*.foo.com`) are supported. `default` is the catch-all. |
| `ssl` | no | `true` / `false`, or an object with `enabled` and `wildcard` keys. Defaults to `false`. |
| `ddns` | no | DDNS config. Omit if the domain does not need dynamic DNS updates. |
| `ddns.provider` | yes if ddns set | `namecheap` or `cloudflare` |
| `ddns.token` | yes | API token or DDNS password. Use `"${VAR}"` syntax to read from env. |

### Secret substitution

Any value matching `"${VAR_NAME}"` is replaced at load time with `System.get_env("VAR_NAME")`.
If the env var is not set, startup fails with a clear error. This keeps secrets out of the
config file while allowing the file to be checked into version control.

### SSL domain derivation

The loader automatically builds the `LETSENCRYPT_DOMAINS` list from the config. For each
service where `ssl` is enabled, all `domains` entries that are not glob patterns and not
`default` are collected as SSL domains. The wildcard entry `*.foo.com` is excluded but
`foo.com` is included, because Let's Encrypt issues the cert for the root domain and its
wildcard as a pair.

### What stays in `.env`

Only secrets and infrastructure-level settings that are node-specific:

```bash
# Secrets
SECRET_KEY_BASE=...
METRICS_AUTH_TOKEN=...
CLUSTER_SECRET=...

# DDNS tokens (referenced via ${} in gateway.yaml)
SEVENEAT_DDNS_TOKEN=...
EN2FE_DDNS_TOKEN=...
CF_API_TOKEN=...
WRITEINONE_CF_ZONE_ID=...

# Infrastructure
NODE_WEIGHT=70
CLUSTER_PEERS=...
GATEWAY_CONFIG_FILE=/etc/elixir_gateway/gateway.yaml
```

### Interaction with dynamic services

`gateway.yaml` provides the static routing layer. The dynamic service registry
(`dynamic_services.json`, from the dynamic services spec) is checked first on every
request. If no dynamic entry exists for a host, the gateway falls back to the static
config from `gateway.yaml`. The two sources are never merged — dynamic always wins for
any host it knows about.

### What needs to be built

- `ElixirGateway.ConfigLoader` — reads and parses `gateway.yaml` at startup, performs
  `${}` substitution, produces the same internal config maps that `runtime.exs` currently
  builds from env vars.
- Updates to `runtime.exs` — `GATEWAY_SERVICES`, `LETSENCRYPT_DOMAINS`, `DDNS_DOMAINS`
  env vars continue to work as before. If `GATEWAY_CONFIG_FILE` is set, the file takes
  precedence and the flat env vars are ignored. This allows a gradual migration.
- Updates to `DomainRouter` — read static routes from `ConfigLoader` instead of directly
  from `Application.get_env`.

---

## 2. Wildcard SSL and Cloudflare Integration

### Why wildcard certs

A wildcard cert for `*.writeinone.com` covers every subdomain with a single cert renewed
once per 90 days, regardless of how many users have a `username.writeinone.com` subdomain.
Without it, each subdomain would need its own cert.

### Why HTTP-01 is not enough for wildcards

Let's Encrypt only issues wildcard certs via DNS-01 challenge. The gateway must prove it
controls the domain by creating a `_acme-challenge.writeinone.com` TXT record, not by
serving a file over HTTP. This requires programmatic access to the domain's DNS provider.

### Why Cloudflare for writeinone.com

The existing Namecheap DDNS API only updates A records — it cannot create TXT records
needed for DNS-01. The full Namecheap DNS API can, but it requires the calling IP to be
whitelisted, which is incompatible with a dynamic home IP.

Cloudflare's DNS API has no IP restrictions, is free, and is well-supported by acme.sh.
Cloudflare also sells domains at cost with no registrar markup, making it the natural
choice for future domain purchases.

**Existing domains** (seveneat.com, en2fe.com, day-20.com, etc.) stay on Namecheap. They
use HTTP-01 certs via SiteEncrypt, which continues to work exactly as today. No migration
needed.

**writeinone.com** moves to Cloudflare registrar. This is the only domain needing a
wildcard cert right now.

**Future domains** are purchased directly through Cloudflare.

### Cert issuance for wildcard domains

Wildcard certs are managed outside SiteEncrypt using acme.sh, since SiteEncrypt's native
client only supports HTTP-01. acme.sh runs as a cron job and stores certs to disk.

**One-time setup:**

```bash
# Install acme.sh
curl https://get.acme.sh | sh

# Set Cloudflare credentials (read from env, not hardcoded)
export CF_Token="..."
export CF_Zone_ID="..."

# Issue wildcard cert
acme.sh --issue --dns dns_cf \
  -d writeinone.com \
  -d "*.writeinone.com" \
  --cert-file /etc/elixir_gateway/certs/writeinone.com/cert.pem \
  --key-file  /etc/elixir_gateway/certs/writeinone.com/key.pem \
  --reloadcmd "kill -USR1 $(cat /var/run/elixir_gateway.pid)"
```

acme.sh auto-renews via cron at 60 days. The `--reloadcmd` signals the gateway to reload
the cert after renewal without a full restart.

### Cert storage layout

```
/etc/elixir_gateway/certs/
  site_encrypt/          ← SiteEncrypt manages this (existing domains, HTTP-01)
  wildcard/
    writeinone.com/
      cert.pem
      key.pem
  custom/                ← per-domain certs for writeinone users (see section 3)
    blog.johndoe.com/
      cert.pem
      key.pem
    journal.alice.io/
      cert.pem
      key.pem
```

### SNI callback

Bandit supports a custom SNI callback that is consulted on every TLS handshake before any
HTTP is read. The gateway registers a callback that checks cert sources in order:

```
Client TLS ClientHello with SNI: "blog.johndoe.com"
  1. Check custom domain cert store (ETS cache → disk)
  2. Check wildcard cert store (covers *.writeinone.com)
  3. Fall back to SiteEncrypt cert (covers your own domains)
```

This allows a single listener on port 443 to serve correct certs for all domain types.

### DDNS with Cloudflare

The existing `ElixirGateway.Cluster.DDNS.Namecheap` module is joined by a new
`ElixirGateway.Cluster.DDNS.Cloudflare` module. Both implement the same behaviour:
`update_all(domains, ip)`.

The DDNS updater reads the provider from each service's `ddns.provider` field in
`gateway.yaml` and dispatches to the correct module. Namecheap and Cloudflare domains
are updated in the same pass — no separate configuration needed.

**Cloudflare DDNS update:** a single `PATCH` request to the Cloudflare DNS API to update
the A record for the domain. Requires `zone_id` and an API token with `Zone.DNS:Edit`
permission.

### What needs to be built

- `ElixirGateway.Cluster.DDNS.Cloudflare` — Cloudflare DNS A record updater.
- Updates to `ElixirGateway.Cluster.DDNS` dispatcher — reads provider from config,
  routes to correct module.
- SNI callback registration in `ElixirGatewayWeb.Endpoint` or application startup.
- Cert reload signal handler (`USR1`) — reloads wildcard and custom cert files from disk
  without restarting.

---

## 3. Custom Domains for Multi-Tenant Services (writeinone)

### Overview

writeinone.com allows users to point their own domain (e.g. `blog.johndoe.com`) at the
gateway via a CNAME record. The gateway must:

1. Accept and route requests for that domain to the writeinone service.
2. Obtain and renew an SSL cert for that domain automatically.
3. Report cert status back to writeinone so the user can be told whether their domain is
   active.

This is a runtime-only, API-driven feature. User domains never appear in `gateway.yaml`.

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
  3. Async: starts ACME HTTP-01 order with Let's Encrypt.
     → LE issues challenge token.
     → gateway stores token in memory.
  4. Let's Encrypt validates:
     GET http://blog.johndoe.com/.well-known/acme-challenge/<token>
     → user's CNAME points to gateway → gateway serves token → LE satisfied.
  5. Cert issued (typically 5–30 seconds).
     → cert written to /etc/elixir_gateway/certs/custom/blog.johndoe.com/
     → cert loaded into ETS cert cache.
     → cert_state: "issued"
     → SNI callback now returns this cert for blog.johndoe.com.
```

Between steps 2 and 5, HTTPS is not yet available for the domain. HTTP works immediately.
writeinone should poll cert status and show the user a "setting up HTTPS" state.

### DNS propagation delay

Users frequently register a domain before updating their DNS. If the CNAME is not yet
pointing to the gateway, the ACME HTTP-01 challenge will fail.

The gateway handles this with a retry scheduler:
- Retry every 5 minutes for the first hour.
- Retry every hour after that.
- writeinone can poll `GET /custom-domains/blog.johndoe.com` to get current `cert_state`
  and surface the correct message to the user ("waiting for DNS", "issuing certificate",
  "active").

### Persistence

`custom_domains.json` is written atomically (write to `.tmp` then rename) after every
state change, following the same pattern as `dynamic_services.json`.

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
disk. Domains with `cert_state: "pending"` resume their retry schedule.

### Cert renewal

A daily scheduler scans `custom_domains.json` for certs expiring within 30 days and
re-runs the ACME HTTP-01 flow for each. The 30-day window against a 90-day cert lifetime
provides two full retry cycles if renewal fails on the first attempt.

### Routing

`DomainRouter` lookup order for an incoming request:

```
1. Dynamic service registry (dynamic_services.json)
2. Custom domain registry (custom_domains.json)
   → match: look up service name → find target in gateway.yaml or dynamic registry
   → forward with original Host header preserved
     (writeinone uses Host header to identify which blog to serve)
3. Static config (gateway.yaml)
4. Default service
```

### Rate limits

Let's Encrypt allows 300 new orders per 3 hours per account. For a small number of paid
users with custom domains this is not a concern. If writeinone grows to where this becomes
a limit, the standard mitigation is to offer custom domains only to paying users, which
naturally caps volume.

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
  Removes domain from registry and deletes cert files.
  Called by writeinone when a user removes their custom domain.
  Response 200: ok
```

### Cluster behaviour

Each gateway node manages its own `custom_domains.json` and cert files independently.
writeinone should register a custom domain on every gateway node it can reach on the
internal network, or only on the primary node if a single node handles DNS traffic.

Cert files can be synced to secondary nodes via the existing `CertificateManager` RPC
mechanism, extended to handle the `certs/custom/` directory in addition to the
SiteEncrypt cert.

### What needs to be built

| Component | Notes |
|---|---|
| `ElixirGateway.CustomDomainRegistry` | GenServer + ETS. Mirrors ServiceRegistry pattern. |
| `ElixirGateway.AcmeClient` | Minimal ACME v2 HTTP-01 client using Req. ~150 lines. |
| `ElixirGateway.CertRenewalScheduler` | Daily scan + renewal trigger for custom domain certs. |
| `/custom-domains` internal API routes | Additions to `InternalController`. |
| `DomainRouter` update | Add custom domain lookup between dynamic registry and static config. |
| SNI callback | Registered at startup. Checks custom → wildcard → SiteEncrypt cert stores. |
| Cert reload on `USR1` | Reloads cert files from disk into ETS without restart. |
| `CertificateManager` extension | Sync `certs/custom/` to secondary nodes via existing RPC. |

---

## Implementation Order

1. `gateway.yaml` loader + migration from env vars — self-contained, unblocks everything else.
2. Cloudflare DDNS module — small, needed once writeinone.com moves to Cloudflare.
3. SNI callback + cert store — needed before wildcard and custom domain certs can be served.
4. Wildcard cert setup (acme.sh + Cloudflare) — operational step, minimal code change.
5. `CustomDomainRegistry` + `AcmeClient` — core of the writeinone custom domain feature.
6. `CertRenewalScheduler` + retry logic — operational hardening.
7. `CertificateManager` extension for custom cert sync — cluster hardening.
