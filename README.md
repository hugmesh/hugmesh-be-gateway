# snapdragon-be-gateway

The **backend front door** of a Snapdragon brand: the per-node-type instance of
the shared [snapdragon-gateway](https://github.com/Snapdragon-Systems/snapdragon-gateway)
Spring Cloud Gateway, deployed into the **backend tier** to sit in front of the
API and the social homeservers (Matrix / Mastodon).

It is **not its own service codebase**. It is a thin **overlay** that re-uses the
audited `snapdragon-gateway` image and changes only three things:

1. its **identity** — `SPRING_APPLICATION_NAME=snapdragon-be-gateway`;
2. its **route set** — a single catch-all `Path=/**` route to the backend API;
3. its **downstream URI** — the in-cluster API service.

Everything else (the OAuth2 resource-server, the JWT→authority conversion, the
domain-scoping, the per-gateway route-access enforcement, revocation, downstream
mTLS) is **inherited unchanged** from the shared gateway image, so every device
runs identical, audited gateway code regardless of node type.

```bash
# GATEWAY_IMAGE must point at the sibling snapdragon-gateway image (CI passes the
# same-namespace tag automatically; see .gitlab-ci.yml).
docker build --build-arg GATEWAY_IMAGE=snapdragon-systems/gateway:dev \
  -t snapdragon-systems/be-gateway:dev .
```

---

## Current State

- **Baseline:** rides the **Spring Boot 4.0.2 / Spring Cloud 2025.1** ecosystem
  baseline through the inherited `snapdragon-gateway` image (shared
  `snapdragon-parent` metapom + `snapdragon-commons` security/tenancy). This overlay
  carries no Java of its own, so it inherits the baseline transparently on the next
  build of the pinned `GATEWAY_IMAGE`.
- **SCG 5.0 route namespace — fixed & shipped on `main`.** Spring Cloud Gateway 5.0
  (Boot 4) moved route config from `spring.cloud.gateway.routes` to
  `spring.cloud.gateway.server.webflux.routes`; the legacy prefix silently binds
  **nothing**. `application-be.yml` now declares the `be-default` `Path=/**` route
  under `spring.cloud.gateway.server.webflux.routes`, so the catch-all to the backend
  API is honoured again. (Route-registry seeding via Liquibase into `gateway_routes`
  is unaffected — that path was never namespace-sensitive.)
- **Auth posture — pure Casdoor-JWT resource server.** The be-gateway validates the
  **internal Casdoor JWT** and runs the inherited authority/domain/route-access stack;
  it **exposes no login**. In the current SSO model, browsers hold only an opaque
  `bff_`-prefixed session and the per-session JWT custody/refresh + the `bff_`→custody-JWT
  swap live **upstream of this overlay** (login-ui + user-bff + the shared gateway
  pre-security filter), so nothing in this repo changes for that model.
- **Authorization data source.** Route-access rows remain admin-managed in Postgres
  (`gateway_route_access`, source of truth), CRUDed by `snapdragon-admin-bff-api`;
  this repo only seeds the `be-default` row into the `gateway_routes` **registry**.
- **Forgejo service-catalog deploy descriptor — shipped dark on `main`.** A
  `snapdragon-deploy.yaml` descriptor + a `deploy/` kustomize dir (the gateway Helm
  chart rendered byte-for-byte to static manifests) are on `main` for the Phase-6
  Forgejo catalog ApplicationSet. They **change nothing running**: the live ArgoCD
  source is still the `snapdragon-gateway` Helm chart in `snapdragon-generator`, and
  the GitHub-rooted control plane ignores these files until the Forgejo cutover.
- **CI:** GitLab (in-cluster). No GitHub Actions in this repo.

---

## Where it sits

| | |
|---|---|
| **Tier** | backend (data-plane front door) |
| **Namespace** | `snapdragon-backend` |
| **Identity** | `snapdragon-be-gateway` (the `gateway` column for its route-access rows) |
| **Downstream** | `snapdragon-api.snapdragon-backend.svc.cluster.local:8080` (override `DOWNSTREAM_URI`) |
| **Auth** | validates the **internal Casdoor JWT** as an OAuth2 resource server; **no external login is exposed** |
| **Base image** | `snapdragon-gateway` (one image, differentiated by `SPRING_APPLICATION_NAME`) |

A brand typically runs several gateway INSTANCES off this one image —
`snapdragon-be-gateway` (backend), `snapdragon-fe-gateway` (front door),
`snapdragon-pki-gateway`/`snapdragon-id-gateway` (identity), etc. — each with its
own name, route set and route-access rows. This repo is the backend one.

### What's in this repo

| File | Purpose |
|------|---------|
| `Dockerfile` | `FROM ${GATEWAY_IMAGE}` then bakes the be identity + config + Liquibase changelog onto the shared image |
| `application-be.yml` | overlay config: `application.name`, the Casdoor `issuer-uri`, and the single `be-default` `Path=/**` route to the API, declared under `spring.cloud.gateway.server.webflux.routes` (SCG 5.0 / Boot 4 namespace; loaded via `SPRING_CONFIG_ADDITIONAL_LOCATION`) |
| `liquibase/changelog/db.changelog-master.xml` | Liquibase **master changelog** — the entry point the base gateway image runs; it `<include>`s `001-gateway-routes.xml` (`relativeToChangelogFile="true"`) |
| `liquibase/changelog/001-gateway-routes.xml` | seeds the `be-default` route (`Path=/**` → API) into the DB-backed route **registry** (`gateway_routes`) |
| `.gitlab-ci.yml` | builds + pushes this overlay image, basing the build off the sibling `snapdragon-gateway` image in the same in-cluster GitLab registry namespace |
| `snapdragon-deploy.yaml` | per-repo deploy descriptor for the Phase-6 Forgejo **service-catalog** ApplicationSet (name/namespace/image/port). **Ships dark:** the live ArgoCD source today is the `snapdragon-gateway` Helm chart in `snapdragon-generator`, so this descriptor + `deploy/` change nothing running until the Forgejo cutover |
| `deploy/` | the gateway Helm chart **rendered to static kustomize manifests** (`serviceaccount`/`configmap`/`service`/`deployment`/`ingress` + `kustomization.yaml`) — a verbatim, byte-identical dark copy of today's live render, kept for the Forgejo-source cutover; not consulted by the current GitHub-rooted ArgoCD |

CI is **GitLab** (in-cluster). There are no GitHub Actions workflows in this repo.

---

## Inherited capabilities (from `snapdragon-gateway`)

> **Reference summary, not local behavior.** Everything in this section is owned by
> and **authoritative in** [`snapdragon-gateway`](https://github.com/Snapdragon-Systems/snapdragon-gateway)
> — not defined or verifiable in this repo. This overlay contributes only
> `application-be.yml` + the `gateway_routes` seed (see [What's in this repo](#whats-in-this-repo)).
> Treat the descriptions below as a convenience digest; if they drift from the base
> gateway, the base repo wins. The base image is pinned by tag via the `GATEWAY_IMAGE`
> build-arg (CI passes `…/snapdragon-gateway:$CI_COMMIT_REF_SLUG`; see `.gitlab-ci.yml`),
> so the exact inherited code is traceable per build. Edit base-gateway behavior there,
> not here.

Because the image is the shared gateway, the be-gateway gets the full gateway
authorization stack for free. The relevant pieces for the backend front door:

### Casdoor resource server + role authorities

Every request must carry a valid internal Casdoor JWT (issuer `CASDOOR_ISSUER_URI`,
default `https://id.snapdragon.systems`). The shared `CasdoorAuthorities` converter
maps the token to Spring authorities:

- a `ROLE_USER` floor on every authenticated principal;
- `roles` claim → `ROLE_<UPPER>` (handles Casdoor's string-or-object role shape);
- `permissions` claim → verbatim authorities, **except** any entry beginning with a
  reserved prefix (`ROLE_` / `DOMAIN_`) is dropped — authority-injection defense;
- legacy `isAdmin: true` → `ROLE_ADMIN`;
- exactly one issuer-derived `DOMAIN_<x>` authority, keyed on the
  cryptographically-validated `iss` (never a user-settable claim).

The least-privilege cascade is `SUPERADMIN > ADMIN/MOD > USER` (with `MOD` and
`ADMIN` as siblings), plus the separate `ROLE_IMAGE_BUILDER` capability.

The browser-facing SSO model (login-ui Casdoor OIDC/PKCE redirect, user-bff
server-side code→token exchange + per-session JWT custody/refresh, and the opaque
`bff_`→internal-JWT swap performed by a shared pre-security gateway filter) is owned
upstream; from this overlay's perspective the request that reaches it already carries
a validated internal Casdoor JWT.

### Domain scoping (multi-tenancy)

`DomainRegistry` resolves the validated issuer → brand/domain. It is **opt-in and
backward-compatible**: with `APP_TENANCY_ISSUERS` unset, the lone configured issuer
maps to `DOMAIN_default` and a single-issuer cluster behaves exactly as before. When
populated, only listed per-brand Casdoors are trusted and an unknown `iss` **fails
closed (401)**. The `GatewayRouteAccessFilter` then **hard-denies** any
non-`SUPERADMIN` principal whose own `DOMAIN_<x>` does not match the request's target
domain (derived from `Host`) — closing the cross-tenant hole before the grant layer
is even consulted. `ROLE_SUPERADMIN` is the **only** cross-domain bypass (the infra
control plane).

### Authorization filter chain

The shared WebFilters run (after Spring Security authenticates the JWT) in order:

| Order | Filter | Role in front of the API |
|------:|--------|--------------------------|
| +100 | `RevocationGatewayFilter` | reject revoked Casdoor tokens (Cassandra-cached) |
| +200 | `ExternalAuthHeaderFilter` | inject additive `External-Authorization` headers when an external-OAuth token is present (never required) |
| +250 | `GatewayRouteAccessFilter` | **per-gateway external-access rules** + the cross-domain hard-deny / `SUPERADMIN` bypass |
| +300 | `ResourceAccessFilter` | per-resource grants — a base-image filter that is **inert on the backend route set** (it gates other gateway siblings, not this `Path=/**` API front door) |

`ROLE_ADMIN` on the internal JWT
bypasses the access filters **within its own domain**, so the admin who manages the
rules is never locked out.
A `HomeserverTokenRevocationFilter` covers the Matrix/Mastodon passthrough surface,
where requests carry an opaque homeserver bearer instead of a Casdoor JWT.

### Per-gateway route access

`GatewayRouteAccessService` enforces the admin-managed "which roles/users may reach
which URLs from outside **this** gateway" rules. **Postgres is the source of truth**
(`ROUTE_ACCESS_R2DBC_URL`); the pod loads the `gateway_route_access` rows for its own
`spring.application.name` (= `snapdragon-be-gateway`), write-through-mirrors them into
the Cassandra read-cache, and refreshes every tick. If Postgres is briefly
unreachable it serves the last-known Cassandra rows; if neither is configured it falls
back to the baked-in canonical seed — **never silently fail-open**. The admin-bff
(`snapdragon-admin-bff-api`) CRUDs the canonical rows. Longest-matching `url_pattern`
wins; explicit `allow=false` denies; the `PUBLIC` sentinel permits anonymous traffic.

> **Which table this repo touches.** Don't confuse the two route tables. This repo's
> Liquibase changelog seeds **only** the `gateway_routes` route **registry** (the one
> `be-default` `Path=/**` → API row). The `gateway_route_access` **authorization** rows
> for `spring.application.name=snapdragon-be-gateway` are seeded and CRUDed by
> `snapdragon-admin-bff-api`, **not here**.

### Downstream mTLS (gateway → API)

When the backend enforces mTLS (`server.ssl.client-auth=need`), set
`SNAPDRAGON_GATEWAY_MTLS_ENABLED=true` and the gateway presents a client cert chaining
to the cluster CA on the proxy leg (stores assembled in-pod from `snapdragon.tls.*`,
passwords never in git). Default off keeps local/dev/CI proxying plain `http://`.
**Upstream (public) callers are unaffected** — this configures only the gateway's
outbound client.

---

## Configuration

Overlay-relevant env vars (the full set is documented in `snapdragon-gateway`):

| Env var | Default | Purpose |
|---------|---------|---------|
| `SPRING_APPLICATION_NAME` | `snapdragon-be-gateway` | gateway identity + route-access `gateway` key (baked into the image) |
| `CASDOOR_ISSUER_URI` | `https://id.snapdragon.systems` | trusted Casdoor issuer for JWT validation |
| `DOWNSTREAM_URI` | `http://snapdragon-api.snapdragon-backend.svc.cluster.local:8080` | the API this gateway fronts |
| `APP_TENANCY_ISSUERS` | _(empty)_ | CSV `issuerUri=domain,…` — enables multi-brand mode (empty ⇒ single-tenant `default`) |
| `APP_TENANCY_HOSTS` | _(empty)_ | CSV `hostSuffix=domain,…` — defense-in-depth Host→domain map |
| `ROUTE_ACCESS_R2DBC_URL` | _(empty)_ | Postgres source-of-truth for route-access rows (empty ⇒ Cassandra-cache/seed only) |
| `SNAPDRAGON_GATEWAY_MTLS_ENABLED` | `false` | present a client cert to mTLS-enforcing backends |

---

## Relationship to the platform

- **Gateways** — one shared `snapdragon-gateway` image; this overlay is its backend
  instance. The fe-gateway and identity gateways are siblings off the same image
  (an optional games gateway is another sibling when the opt-in games service is
  enabled).
- **Casdoor** — the gateway is a resource server only; it validates JWTs minted by the
  brand's Casdoor and never exposes a login. Browser-facing SSO (OIDC/PKCE) is handled
  by login-ui + user-bff, which hand this gateway a validated internal JWT.
- **Federation** — the same domain-scoping and route-access rows that gate ordinary
  traffic also gate federated/remote surfaces; `SUPERADMIN` is the only cross-domain
  reach.
- **Multi-tenancy** — per-brand instances each carry their own issuer + `gateway`
  name + route-access rows; `DOMAIN_<x>` scoping + the cross-domain hard-deny enforce
  brand isolation at the gateway.

---

## Roadmap

> State convention: 🚧 **in-flight** = code on an open branch/PR, not yet merged ·
> 🔭 **planned** = design-complete, no code. Nothing below is shipped on `main`.
> These are **inherited / upstream** changes — none expected to alter the files in
> this overlay repo, but each affects how this be-gateway behaves once the base
> `snapdragon-gateway` image (pinned by `GATEWAY_IMAGE`) picks them up.

- 🚧 **SSO end-to-end + e2e.** The Casdoor OIDC/PKCE login model (login-ui → user-bff
  custody JWT → opaque `bff_` browser session, swapped to the internal JWT by the
  shared pre-security gateway filter) is being driven to a live, e2e-tested state
  upstream. This be-gateway inherits the `bff_`→JWT swap from the base image; no local
  change here.
- 🚧 **MFA-gated routes (Casdoor MFA).** A base-gateway capability: a
  `gateway_route_access.mfa_required` column plus `amr`/`acr` → `MFA_SATISFIED`
  **fail-closed** enforcement. Once shipped upstream, the be-gateway will inherit
  `mfa_required` enforcement for its backend routes. No local change here — it only
  affects the `gateway_route_access` rows (CRUDed by admin-bff) that target
  `snapdragon-be-gateway`.
- 🚧 **New backend API surfaces behind `Path=/**`.** Notifications **external
  channels** (Matrix DM / Akkoma feed / phpBB / email adapters) and the **Workload
  Console** (admin-bff changelog 110-band) add API endpoints that this catch-all route
  fronts. No change to this repo; if a future README ever enumerates what the backend
  API exposes, these must be marked roadmap, not shipped.
- 🔭 **Auth-core relocation (upstream).** Login/session/account logic is being
  relocated from admin-bff to user-bff, with shared account/session/MFA/Casdoor-admin
  infra extracted to `snapdragon-auth-core` (consumed by user-bff + admin-bff only).
  This is invisible to the be-gateway — it still validates the internal Casdoor JWT —
  but it is why admin-bff remains the CRUD owner of `gateway_route_access` while
  account/session **data** stays in admin-bff-db.
- 🚧 **Upstream supply-chain hardening.** Base-image and binary checksum/GPG
  verification is being added in the generator/base build, not here — relevant only
  insofar as this overlay pins `GATEWAY_IMAGE` by tag, so a hardened base image flows
  through transparently on the next build.
