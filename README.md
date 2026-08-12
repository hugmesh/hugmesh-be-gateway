# hugmesh-be-gateway

The **backend front door** of a HugMesh brand: a per-brand deployment of the
shared [hugmesh-gateway](https://github.com/hugmesh-net/hugmesh-gateway)
Spring Cloud Gateway, placed in the **backend tier** to sit in front of the
backend API and the social homeservers (Matrix / Mastodon).

This repo is **not its own service codebase**. It is a thin **overlay** — a
minimal `Dockerfile` plus a config file and a Liquibase changelog — that re-uses
the audited `hugmesh-gateway` image and changes only three things:

1. its **identity** — `SPRING_APPLICATION_NAME=hugmesh-be-gateway`;
2. its **route set** — a single catch-all `Path=/**` route to the backend API;
3. its **downstream URI** — the in-cluster API service URL.

Everything else (the OAuth2 resource-server, the JWT-to-authority conversion, the
domain-scoping, the per-gateway route-access enforcement, revocation, downstream
mTLS) is **inherited unchanged** from the shared gateway image, so every device
runs identical, audited gateway code regardless of node type.

```mermaid
flowchart TB
    client["External caller\n(JWT in Authorization header)"]
    beg["hugmesh-be-gateway\n(this repo — overlay image)"]
    api["hugmesh-api\n(backend API service)"]
    base["hugmesh-gateway\n(shared base image)"]

    client -->|HTTPS + Casdoor JWT| beg
    beg -->|"proxy (HTTP or mTLS)"| api
    beg -. "FROM (all auth + filter logic)" .-> base
```

```bash
# GATEWAY_IMAGE must point at the sibling hugmesh-gateway image.
# CI resolves this automatically from the same namespace (see .gitlab-ci.yml);
# for local builds, supply whatever tag you have pulled locally.
docker build --build-arg GATEWAY_IMAGE=hugmesh-systems/hugmesh-gateway:dev \
  -t hugmesh-systems/be-gateway:dev .
```

---

## Status

- **Last synced:** 2026-07-22
- **Overlay config now actually loads — fixed & shipped on `main` (PR #17,
  2026-07-17).** `application-be.yml` is a profile-specific document
  (`application-{profile}.yml`); `SPRING_CONFIG_ADDITIONAL_LOCATION` only adds a
  config *search directory*, it does **not** activate a profile. `Dockerfile` now
  sets `ENV SPRING_PROFILES_ACTIVE=be` so the file is actually read. Before this
  fix the overlay route was silently never loaded and the image fell back to the
  base image's packaged `application.yml` (an `api-default` `/api/**` route) — a
  half-working gateway serving the wrong route table, not a clean failure. The
  dark `deploy/deployment.yaml` copy picked up the analogous
  `SPRING_PROFILES_ACTIVE=routes` line in the same PR; that path stays latent
  until the Forgejo cutover.
- **Rebrand — Snapdragon → HugMesh (PR #18, 2026-07-22).** Image name,
  `SPRING_APPLICATION_NAME`, k8s resource names/labels, the `hugmesh-backend`
  namespace literal, and domain-derived config defaults (`id.hugmesh.systems`
  issuer, `api./scale./games.hugmesh.systems` ingress hosts) are renamed. The
  Cassandra keyspace literal `snapdragon_gateway` in `deploy/deployment.yaml` was
  deliberately left unchanged pending a real keyspace migration, and all of this
  `deploy/` content still ships dark (see below) so the rename has no live effect
  yet.
- **Baseline:** rides the **Spring Boot 4.0.7 / Spring Cloud 2025.1.2** ecosystem
  baseline (on Java 25) through the inherited `hugmesh-gateway` image. That image
  deliberately **keeps `spring-boot-starter-parent`, not the `hugmesh-parent`
  metapom** (which is BFF-focused and would drag in Liquibase / testcontainers-
  postgres / r2dbc-postgres scaffolding the gateway's Cassandra-based suite
  doesn't use), and pins `hugmesh-commons` as a **direct dependency at 2.1.0**
  for its security/tenancy types — not 2.7.0, which is `hugmesh-parent`'s own
  version and was never a published commons coordinate (same mixup already
  fixed in hugmesh-auth-core's README, PR #24). This overlay carries no Java of
  its own, so it inherits the baseline transparently on the next build of the
  pinned `GATEWAY_IMAGE`.
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
  (`gateway_route_access`, source of truth), CRUDed by `hugmesh-admin-bff-api`;
  this repo only seeds the `be-default` row into the `gateway_routes` **registry**.
- **Forgejo service-catalog deploy descriptor — shipped dark on `main`.** A
  `hugmesh-deploy.yaml` descriptor + a `deploy/` kustomize dir (the gateway Helm
  chart rendered byte-for-byte to static manifests) are on `main` for the Phase-6
  Forgejo catalog ApplicationSet. They **change nothing running**: the live ArgoCD
  source is still the `hugmesh-gateway` Helm chart in `hugmesh-generator`, and
  the GitHub-rooted control plane ignores these files until the Forgejo cutover.
- **Two different route tables exist — do not conflate them.** This repo's own
  overlay contribution (`application-be.yml` + the Liquibase `gateway_routes` seed)
  is genuinely just a single `Path=/**` catch-all to the API — that's the entirety
  of what this repo emits. But `deploy/configmap.yaml` (captured by PR #9 as a
  byte-identical snapshot of the **live** Helm-rendered route ConfigMap actually
  mounted onto the be-gateway pod) shows the route table the cluster runs today is
  sourced from `hugmesh-generator`'s `apps/20-gateway-be.yaml` Helm values, not
  from this repo, and is materially richer: 11 explicit routes (games, matrix,
  mastodon, headscale-forward, federation-api, hugmesh-api) with **no bare
  `Path=/**` entry at all**. `deploy/deployment.yaml` also shows the live pod
  running the **base** `hugmesh-systems/gateway:dev` image directly, not an
  image built from this repo's `Dockerfile` — so it's unclear from this repo alone
  whether the overlay image `.gitlab-ci.yml` builds and pushes is consumed by
  anything today. That snapshot was verified byte-identical on **2026-06-23**
  (PR #9) and hasn't been re-synced since — treat it as directional, not current
  truth, until it's re-checked against the live chart. See **Known Gaps** below.
- **CI:** GitLab (in-cluster). No GitHub Actions in this repo.

```mermaid
flowchart TB
    subgraph repo["This repo — overlay-image build path"]
        appyml["application-be.yml\n(single Path=/** route)"]
        liq["liquibase seed\n(gateway_routes: be-default)"]
        ci["Dockerfile + .gitlab-ci.yml\nbuild + push the overlay image"]
    end

    subgraph live["Live cluster today — Helm chart path"]
        chart["hugmesh-gateway Helm chart\n(hugmesh-generator repo)"]
        cm["rendered route ConfigMap\n(games / matrix / mastodon /\nheadscale-forward / federation-api /\nhugmesh-api -- no bare catch-all)"]
        pod["running be-gateway pod\n(base image + this ConfigMap)"]
        chart --> cm --> pod
    end

    snapshot["deploy/ in this repo:\na dark, point-in-time snapshot\nof the live path (verified 2026-06-23,\nnow stale) -- not the source of truth"]

    pod --> snapshot
```

---

## Where it sits

| | |
|---|---|
| **Tier** | backend (data-plane front door) |
| **Namespace** | `hugmesh-backend` |
| **Identity** | `hugmesh-be-gateway` (the `gateway` column for its route-access rows) |
| **Downstream** | `hugmesh-api.hugmesh-backend.svc.cluster.local:8080` (override `DOWNSTREAM_URI`) |
| **Auth** | validates the **internal Casdoor JWT** as an OAuth2 resource server; **no external login is exposed** |
| **Base image** | `hugmesh-gateway` (one image, differentiated by `SPRING_APPLICATION_NAME`) |

A brand typically runs several gateway instances off this one shared image —
`hugmesh-be-gateway` (backend), `hugmesh-fe-gateway` (front door),
`hugmesh-pki-gateway` / `hugmesh-id-gateway` (identity), etc. — each
differentiated only by its `SPRING_APPLICATION_NAME`, route set, and
route-access rows. This repo is the backend instance.

### What's in this repo

| File | Purpose |
|------|---------|
| `Dockerfile` | `FROM ${GATEWAY_IMAGE}` then bakes the be identity + config + Liquibase changelog onto the shared image |
| `application-be.yml` | overlay config: `application.name`, the Casdoor `issuer-uri`, and the single `be-default` `Path=/**` route to the API, declared under `spring.cloud.gateway.server.webflux.routes` (SCG 5.0 / Boot 4 namespace; loaded via `SPRING_CONFIG_ADDITIONAL_LOCATION`) |
| `liquibase/changelog/db.changelog-master.xml` | Liquibase **master changelog** — the entry point the base gateway image runs; it `<include>`s `001-gateway-routes.xml` (`relativeToChangelogFile="true"`) |
| `liquibase/changelog/001-gateway-routes.xml` | seeds the `be-default` route (`Path=/**` → API) into the DB-backed route **registry** (`gateway_routes`) |
| `.gitlab-ci.yml` | builds + pushes this overlay image, basing the build off the sibling `hugmesh-gateway` image in the same in-cluster GitLab registry namespace |
| `hugmesh-deploy.yaml` | per-repo deploy descriptor for the Phase-6 Forgejo **service-catalog** ApplicationSet (name/namespace/image/port). **Ships dark:** the live ArgoCD source today is the `hugmesh-gateway` Helm chart in `hugmesh-generator`, so this descriptor + `deploy/` change nothing running until the Forgejo cutover |
| `deploy/` | the gateway Helm chart **rendered to static kustomize manifests** (`serviceaccount`/`configmap`/`service`/`deployment`/`ingress` + `kustomization.yaml`) — a verbatim, byte-identical dark copy of today's live render, kept for the Forgejo-source cutover; not consulted by the current GitHub-rooted ArgoCD |

CI is **GitLab** (in-cluster). There are no GitHub Actions workflows in this repo.

---

## Inherited capabilities (from `hugmesh-gateway`)

> **Reference summary only — not local behavior.** Everything in this section is
> owned by and **authoritative in**
> [`hugmesh-gateway`](https://github.com/hugmesh-net/hugmesh-gateway),
> not in this repo. This overlay contributes only `application-be.yml` plus the
> `gateway_routes` seed (see [What's in this repo](#whats-in-this-repo)). Treat
> the descriptions below as a convenience digest; if they drift from the base
> gateway, the base repo wins.
>
> The base image is pinned by tag via the `GATEWAY_IMAGE` build-arg (CI passes
> `.../hugmesh-gateway:$CI_COMMIT_REF_SLUG`; see `.gitlab-ci.yml`), so the
> exact inherited code is traceable per build. To change base-gateway behavior,
> edit that repo — not this one.

Because this overlay uses the shared gateway image, the be-gateway inherits the
full authorization stack at no additional code cost. The pieces most relevant to
the backend front door are described below.

### Casdoor resource server + role authorities

Every request must carry a valid internal Casdoor JWT (issuer `CASDOOR_ISSUER_URI`,
default `https://id.hugmesh.systems`). The shared `CasdoorAuthorities` converter
maps the JWT claims to Spring Security authorities as follows:

- Every authenticated principal receives a `ROLE_USER` floor authority.
- The `roles` claim is mapped to `ROLE_<UPPER>` (handles Casdoor's string-or-object
  role representation).
- The `permissions` claim is mapped verbatim, **except** any entry starting with
  a reserved prefix (`ROLE_` or `DOMAIN_`) is dropped — this prevents
  authority-injection via a crafted token.
- The legacy `isAdmin: true` claim maps to `ROLE_ADMIN`.
- Exactly one `DOMAIN_<x>` authority is derived from the cryptographically-validated
  `iss` field (never from a user-settable claim), binding the principal to a brand.

The least-privilege cascade is `SUPERADMIN > ADMIN / MOD > USER` (where `MOD` and
`ADMIN` are siblings, neither subordinate to the other), plus the orthogonal
`ROLE_IMAGE_BUILDER` capability.

The browser-facing native-login model (a login form served directly by each
service's own login-ui, POSTing to that service's own BFF login endpoint; Casdoor
is internal-only and never redirects the browser, plus the resulting per-session
JWT custody/refresh and the opaque `bff_`→internal-JWT swap performed by a shared
pre-security gateway filter) is owned upstream; from this overlay's perspective the
request that reaches it already carries a validated internal Casdoor JWT.

### Domain scoping (multi-tenancy)

`DomainRegistry` resolves the validated JWT issuer to a brand/domain name. The
feature is **opt-in and backward-compatible**:

- **Single-tenant (default):** with `APP_TENANCY_ISSUERS` unset, the single
  configured issuer maps to `DOMAIN_default` and the cluster behaves as before.
- **Multi-tenant:** when `APP_TENANCY_ISSUERS` is set, only the listed per-brand
  Casdoor issuers are trusted. A token from an unknown `iss` **fails closed (401)**
  rather than being silently accepted.

After JWT validation, `GatewayRouteAccessFilter` **hard-denies** any
non-`SUPERADMIN` principal whose `DOMAIN_<x>` authority does not match the target
domain derived from the `Host` header. This cross-tenant check fires before the
URL-grant layer is consulted, so a legitimately-authenticated user from brand A
can never reach brand B's resources. `ROLE_SUPERADMIN` is the **only** cross-domain
bypass — it exists solely for the infrastructure control plane.

```mermaid
flowchart TB
    jwt["Incoming JWT\n(validated issuer)"]
    dr["DomainRegistry\niss → DOMAIN_x"]
    unknown{"Known issuer?"}
    reject401["401 Rejected"]
    domaincheck{"DOMAIN_x matches\nHost header?"}
    superadmin{"ROLE_SUPERADMIN?"}
    deny403["403 Hard-deny"]
    grantcheck["URL grant check\n(GatewayRouteAccessFilter)"]
    proxy["Proxy to API"]

    jwt --> dr --> unknown
    unknown -- No --> reject401
    unknown -- Yes --> domaincheck
    domaincheck -- Match --> grantcheck
    domaincheck -- Mismatch --> superadmin
    superadmin -- Yes --> grantcheck
    superadmin -- No --> deny403
    grantcheck --> proxy
```

### Authorization filter chain

After Spring Security validates the JWT, the shared `WebFilter` chain runs in
priority order. Filters are listed below as they apply to this repo's own
`Path=/**` overlay route (see the **Status** section's "two different route
tables" note — the live cluster's actual route set is broader and externally
sourced, so treat "this gateway's route" below as this repo's contribution,
not necessarily the pod's full live route table):

| Order | Filter | Role in front of the API |
|------:|--------|--------------------------|
| +100 | `RevocationGatewayFilter` | Rejects tokens that Casdoor has revoked (checked against a Cassandra-backed cache). |
| +200 | `ExternalAuthHeaderFilter` | Injects additive `External-Authorization` headers when an external OAuth token accompanies the request. This header is never required by the backend API. |
| +250 | `GatewayRouteAccessFilter` | Enforces per-gateway URL-access rules and the cross-domain hard-deny / `SUPERADMIN` bypass described above. |
| +300 | `ResourceAccessFilter` | Enforces per-resource grants. **This filter is inert for this gateway's catch-all route** — it gates specific path patterns on other sibling gateways, not the `Path=/**` API front door here. |

`ROLE_ADMIN` bypasses the access filters within its own domain, so the admin
who manages the route-access rules can never lock themselves out.

Requests that carry an opaque homeserver bearer token instead of a Casdoor JWT
(Matrix / Mastodon passthrough traffic) are handled separately by the
`HomeserverTokenRevocationFilter`.

### Per-gateway route access

`GatewayRouteAccessService` enforces the admin-managed rules that decide which
roles or users may reach which URLs through **this** gateway. **Postgres is the
source of truth** (`ROUTE_ACCESS_R2DBC_URL`): on startup the pod loads the
`gateway_route_access` rows scoped to its own `spring.application.name` (=
`hugmesh-be-gateway`), write-through-mirrors them into Cassandra as a
read-cache, and refreshes on each tick. The fallback chain is:

1. Postgres (authoritative) — used when reachable.
2. Cassandra cache — used when Postgres is briefly unavailable.
3. Baked-in canonical seed — last resort; **never silently fail-open**.

The admin-bff service (`hugmesh-admin-bff-api`) creates and manages the
canonical `gateway_route_access` rows. Match semantics: longest `url_pattern`
wins; an explicit `allow=false` row denies; the `PUBLIC` sentinel permits
anonymous traffic.

> **Which table this repo touches.** There are two distinct route tables — do
> not confuse them. This repo's Liquibase changelog seeds only the
> `gateway_routes` **route registry** (one row: `be-default`, `Path=/**` → API).
> The `gateway_route_access` **authorization** rows scoped to
> `spring.application.name=hugmesh-be-gateway` are seeded and managed
> exclusively by `hugmesh-admin-bff-api`, not here.

### MFA-required route enforcement (✅ inherited, ships dark)

> Status: ✅ shipped + tested in the shared gateway image; **feature-flagged dark
> (default off)**, not absent. `gateway_route_access` carries an `mfa_required`
> column, and a deciding grant on a row with `mfa_required=true` additionally
> demands the `MFA_SATISFIED` marker — absent marker means **denied**
> (fail-closed). The D8 privileged-MFA floor sits *above* the `SUPERADMIN`
> cross-domain bypass and the `ADMIN` / `GAME-MASTER` own-domain bypass, so even a `SUPERADMIN`
> reaching an `mfa_required` surface without a fresh second factor is denied.
> Both `app.mfa.enabled` and `app.mfa.enforce-privileged-floor` default `false`
> (ship-dark) — when off, the `mfa_required` column is inert and the gateway is
> byte-identical to its pre-MFA behaviour.

`MFA_SATISFIED` is **not** a role and **not** a permission. It is a non-role
marker authority derived solely from the **BFF-written, freshness-validated
`mfa_satisfied_at` JWT-Custom claim** (epoch-millis carried as a string, stamped
by the BFF on a successful MFA challenge). A stamp is fresh iff
`0 <= now - ts <= app.mfa.freshness-window` (default `600000`, 10 minutes,
independent of the session TTL); a **future** timestamp is rejected as
clock-skew/forged-future. Because `MFA_SATISFIED` is a reserved authority prefix,
a forged `permissions:["MFA_SATISFIED"]` on the token is dropped and can never
inject the marker, and the missing `ROLE_` prefix means it can never accidentally
satisfy a `hasRole()` / route-access role check.

No change to this overlay is required: the enforcement lives in the shared
gateway image's route-access layer, so this be-gateway already carries it. Turning
it on is a matter of flipping the flags plus the `mfa_required` rows that
admin-bff manages for `spring.application.name=hugmesh-be-gateway`.

### Downstream mTLS (gateway → API)

When the backend API enforces mTLS (`server.ssl.client-auth=need`), set
`HUGMESH_GATEWAY_MTLS_ENABLED=true`. The gateway will then present a client
certificate chaining to the cluster CA on the outbound proxy leg; the key material
is assembled in-pod from `hugmesh.tls.*` properties (passwords are never stored
in git). The default is `false`, which keeps local, dev, and CI environments
proxying over plain `http://`. **Inbound (public) callers are unaffected** — this
flag controls only the gateway's outbound TLS client identity.

---

## Configuration

The table below covers the env vars relevant to this overlay. The full set of
base-gateway variables is documented in `hugmesh-gateway`.

| Env var | Default | Purpose |
|---------|---------|---------|
| `SPRING_APPLICATION_NAME` | `hugmesh-be-gateway` | gateway identity + route-access `gateway` key (baked into the image) |
| `CASDOOR_ISSUER_URI` | `https://id.hugmesh.systems` | trusted Casdoor issuer for JWT validation |
| `DOWNSTREAM_URI` | `http://hugmesh-api.hugmesh-backend.svc.cluster.local:8080` | the API this gateway fronts |
| `APP_TENANCY_ISSUERS` | _(empty)_ | CSV `issuerUri=domain,…` — enables multi-brand mode (empty ⇒ single-tenant `default`) |
| `APP_TENANCY_HOSTS` | _(empty)_ | CSV `hostSuffix=domain,…` — defense-in-depth Host→domain map |
| `ROUTE_ACCESS_R2DBC_URL` | _(empty)_ | Postgres source-of-truth for route-access rows (empty ⇒ Cassandra-cache/seed only) |
| `HUGMESH_GATEWAY_MTLS_ENABLED` | `false` | Present a client certificate to the mTLS-enforcing backend API. |

**Multi-tenant example** — to trust two brands with separate Casdoor instances:

```bash
APP_TENANCY_ISSUERS="https://id.alpha.example.com=alpha,https://id.beta.example.com=beta"
APP_TENANCY_HOSTS=".alpha.example.com=alpha,.beta.example.com=beta"
```

With these values set, a JWT with `iss=https://id.alpha.example.com` yields
`DOMAIN_alpha`, and a request to a `Host: api.beta.example.com` endpoint with
a `DOMAIN_alpha` principal is hard-denied before URL grants are checked.

---

## Relationship to the platform

- **Gateways** — one shared `hugmesh-gateway` image powers every gateway in the
  platform. This overlay is the backend instance. The `fe-gateway` and identity
  gateways (`pki-gateway`, `id-gateway`) are siblings built the same way. The
  optional `games.hugmesh.systems` surface is **not** a separate games-specific
  gateway sibling — per `deploy/ingress.yaml` + `deploy/configmap.yaml`, this
  be-gateway instance fronts it directly (its own route table carries the
  `games` and `games-servers-console` routes) when the opt-in games service is
  enabled; there is no distinct games gateway pod.
- **Casdoor** — this gateway is a resource server only. It validates JWTs minted
  by the brand's Casdoor instance and never exposes a login endpoint itself.
  Browser-facing login (a native form in each service's own login-ui, POSTing to
  that service's own BFF login endpoint — Casdoor is internal-only and never
  redirects the browser) is handled by login-ui + user-bff, which hand this
  gateway a validated internal JWT.
- **Federation** — the same domain-scoping and route-access rules that gate
  ordinary traffic also gate federated and remote surfaces. `SUPERADMIN` is the
  only role with cross-domain reach.
- **Multi-tenancy** — each per-brand gateway instance carries its own issuer,
  `SPRING_APPLICATION_NAME`, and route-access rows. The `DOMAIN_<x>` authority
  and the cross-domain hard-deny together enforce brand isolation at the network
  edge.

---

## Known Gaps

- **TODO: reconcile the two route tables.** `application-be.yml`'s single
  `Path=/**` catch-all + the Liquibase `gateway_routes` seed describe only this
  repo's own overlay contribution. The route table actually mounted on the live
  pod (per `deploy/configmap.yaml`, a snapshot captured by PR #9) is sourced
  from the `hugmesh-gateway` Helm chart in `hugmesh-generator` instead,
  and has no bare catch-all at all (games/matrix/mastodon/headscale-forward/
  federation-api/hugmesh-api only). Confirm which is authoritative today and
  re-verify `deploy/` is still byte-identical to the live render — it was last
  confirmed on 2026-06-23 and hasn't been re-synced since. See **Status** above.
- **~~TODO: confirm whether this repo's overlay image is consumed anywhere.~~ —
  ANSWERED 2026-07-17: it is not.** Saying so plainly, as this entry asked.
  `.gitlab-ci.yml` builds and pushes this overlay image, but **nothing deploys
  it**. Four independent checks against `hugmesh-generator`'s `origin/main`:
  1. All three gateway ArgoCD Applications (`specs/cluster/apps/20-gateway-{be,
     fe,pki}.yaml`) set `path: specs/cluster/charts/hugmesh-gateway` — they
     deploy the **chart**, not this repo — and none overrides the image, so all
     three run the chart default
     `registry.hugmesh.systems/hugmesh/hugmesh-gateway` (the shared
     **base** image).
  2. `GATEWAY_IMAGE` — this repo's only build-arg seam — appears **nowhere** in
     `hugmesh-generator`.
  3. An org-wide grep for `image:.*hugmesh-(be|fe|pki)-gateway` returns
     **nothing**.
  4. `hugmesh-generator`'s only mentions of the string `hugmesh-be-gateway`
     are non-deploy uses: the OWASP SCA scan matrix, the `route-access` seed SQL
     (that's `spring.application.name`, not an image), and ArgoCD
     `releaseName`/`instance.name` values.

  `deploy/deployment.yaml` likewise runs the base image directly. So this repo's
  `Dockerfile` / `application-be.yml` / Liquibase overlay mechanism is **not
  exercised by any real deployment path today** — it is a standalone artifact.
  Whether that is intentional (this repo predates the generator's
  route-templating approach and is now vestigial) or an oversight is a product
  decision, not a code fix. Recorded here so nobody assumes `docker build .` of
  this repo produces what actually runs.
- **`deploy/`'s image coordinates have drifted from the chart.**
  `deploy/deployment.yaml` and `deploy/kustomization.yaml` pin
  `hugmesh-systems/gateway:dev` and describe it as the chart default, but the
  chart's current `values.yaml` says
  `registry.hugmesh.systems/hugmesh/hugmesh-gateway:dev`. Both files
  claim to reproduce the live Helm render 1:1; on image coords they no longer do.
  Same 2026-06-23 staleness root cause as the route-table divergence above — fold
  it into the same re-sync rather than patching piecemeal.

---

## Roadmap

> **State convention:** 🚧 **in-flight** = code on an open branch or PR, not yet
> merged · 🔭 **planned** = design-complete, no code yet. Nothing below is fully
> shipped **and enabled**; where a bullet's upstream half has already landed in the
> base image (and merely ships dark behind a flag), it says so explicitly and links
> to the section above that documents it. All items below are **upstream /
> inherited** changes — none are expected to require edits to the files in this
> overlay repo, but each will affect how this be-gateway behaves once the base
> `hugmesh-gateway` image (pinned by `GATEWAY_IMAGE`) picks them up.

- 🚧 **SSO end-to-end + e2e.** The native-login model (each service's own login-ui
  posts a login form directly to that service's own BFF; Casdoor is internal-only
  and never redirects the browser) superseded the older Casdoor OIDC/PKCE
  browser-redirect design and is being driven to a live, e2e-tested state upstream.
  user-bff still custody-JWTs the result into an opaque `bff_` browser session,
  swapped to the internal JWT by the shared pre-security gateway filter. This
  be-gateway inherits the `bff_`→JWT swap from the base image; no local change here.
- 🚧 **MFA enrollment / step-up (Casdoor MFA).** The **gateway leg is already
  shipped** upstream and inherited here — see
  ["MFA-required route enforcement"](#mfa-required-route-enforcement--inherited-ships-dark)
  above for the `gateway_route_access.mfa_required` column, the `MFA_SATISFIED`
  marker derived from the BFF-written `mfa_satisfied_at` claim, and the
  privileged-MFA floor. What is still in flight is the platform-wide half: MFA
  enrollment and step-up (WebAuthn + TOTP + recovery, per-role defaults) in the
  BFFs that write the `mfa_satisfied_at` stamp, the admin-bff-managed
  `mfa_required` rows, and flipping `app.mfa.enabled` /
  `app.mfa.enforce-privileged-floor` from their dark defaults. No change to this
  repo is required — the effect is entirely in the `gateway_route_access` rows
  managed by admin-bff for `hugmesh-be-gateway`.
- 🚧 **New backend API surfaces behind `Path=/**`.** Notifications external channels
  (Matrix DM / Akkoma feed / phpBB / email adapters) and the Workload Console
  (admin-bff changelog 110-band) add new API endpoints that the catch-all route
  will front. No change to this repo; if a future README enumerates the backend API
  surface, those endpoints must be marked roadmap rather than shipped.
- 🔭 **Auth-core relocation (upstream).** Login/session/account logic is being
  relocated from admin-bff to user-bff, with shared account/session/MFA/Casdoor-admin
  infra extracted to `hugmesh-auth-core` (consumed by user-bff + admin-bff only).
  This is invisible to the be-gateway — it still validates the internal Casdoor JWT —
  but it is why admin-bff remains the CRUD owner of `gateway_route_access` while
  account/session **data** stays in admin-bff-db.
- 🚧 **Upstream supply-chain hardening.** Base-image and binary checksum/GPG
  verification is being added in the generator and base build pipeline, not here.
  This overlay will receive the hardened base image transparently on the next build,
  because `GATEWAY_IMAGE` is pinned by tag.
