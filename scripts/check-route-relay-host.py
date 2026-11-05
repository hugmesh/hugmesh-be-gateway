#!/usr/bin/env python3
"""A gateway-to-gateway relay route must preserve the original Host header.

Usage: check-route-relay-host.py [path/to/configmap.yaml]   (default: deploy/configmap.yaml)
Exit 0 = every relay route carries PreserveHostHeader. Exit 1 = a relay route lacks
it, or no relay route was found at all (the check would otherwise pass vacuously).
Exit 2 = the file could not be read or parsed.

hugmesh-generator#622. The `headscale-forward` route relays Host=scale.<domain> to
the pki gateway, whose own headscale route and host gate match on that same Host.
Spring Cloud Gateway sends the UPSTREAM URI's host unless the route carries the
PreserveHostHeader filter, so without it the pki gateway sees its own Service DNS
name, no route matches, and headscale is unreachable through the only external
path. The rule is stated generally, as in hugmesh-generator's [relay-host] check
(tests/scripts/cluster_manifest_integrity.py): any route with a Host= predicate
whose uri is another gateway Service must preserve the Host.

Needs PyYAML. A missing PyYAML is an error (exit 2), never a skip.
"""
import os
import re
import sys

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is not installed; the relay-host check cannot run", file=sys.stderr)
    sys.exit(2)

# Same pattern as hugmesh-generator's GATEWAY_URI_RE: the target host's first
# label ends in "-gateway" (hugmesh-pki-gateway.hugmesh-pki.svc..., etc.).
GATEWAY_URI_RE = re.compile(r"^https?://[a-z0-9{}.-]*-gateway\.[a-z0-9{}.-]+")
ROUTES_KEY = "application-routes.yml"


def routes_of(path):
    with open(path, encoding="utf-8") as fh:
        docs = [d for d in yaml.safe_load_all(fh) if d]
    out = []
    found_key = False
    for d in docs:
        if d.get("kind") != "ConfigMap":
            continue
        inner = (d.get("data") or {}).get(ROUTES_KEY)
        if inner is None:
            continue
        found_key = True
        cfg = yaml.safe_load(inner) or {}
        node = cfg
        for k in ("spring", "cloud", "gateway", "server", "webflux", "routes"):
            node = (node or {}).get(k) if isinstance(node, dict) else None
        if not isinstance(node, list):
            raise ValueError("%s: data.%s has no spring.cloud.gateway.server.webflux.routes list"
                             % (path, ROUTES_KEY))
        out.extend(r for r in node if isinstance(r, dict))
    if not found_key:
        raise ValueError("%s: no ConfigMap with data.%s" % (path, ROUTES_KEY))
    return out


def name_of(entry):
    """`Host=a,b` / `PreserveHostHeader` / {name: X, args: ...} -> the bare name."""
    if isinstance(entry, dict):
        return str(entry.get("name") or "")
    return str(entry).split("=", 1)[0].strip()


def hosts_of(route):
    hosts = []
    for p in route.get("predicates") or []:
        if name_of(p) != "Host":
            continue
        if isinstance(p, dict):
            args = p.get("args") or {}
            hosts.extend(str(v) for v in (args.values() if isinstance(args, dict) else [args]))
        else:
            hosts.append(str(p).split("=", 1)[1] if "=" in str(p) else "")
    return hosts


def main(argv):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = argv[1] if len(argv) > 1 else os.path.join(root, "deploy", "configmap.yaml")
    try:
        routes = routes_of(path)
    except (OSError, ValueError, yaml.YAMLError) as e:
        print("ERROR: %s" % e, file=sys.stderr)
        return 2
    relays = 0
    bad = 0
    for r in routes:
        hosts = hosts_of(r)
        uri = str(r.get("uri") or "")
        if not hosts or not GATEWAY_URI_RE.match(uri):
            continue
        relays += 1
        if "PreserveHostHeader" not in [name_of(f) for f in (r.get("filters") or [])]:
            bad += 1
            print("FAIL [relay-host] route %r relays Host=%s to another gateway (%s) without the "
                  "PreserveHostHeader filter, so the upstream gateway sees its own Service DNS "
                  "name and its host-predicated routes can never match"
                  % (r.get("id"), ",".join(hosts), uri))
    if not relays:
        print("FAIL [relay-host] found no host-predicated gateway-to-gateway route in %s; the "
              "headscale-forward relay is gone or this check went vacuous" % path)
        return 1
    if bad:
        return 1
    print("ok   [relay-host] all %d host-predicated gateway-to-gateway relay(s) in %s preserve "
          "the Host header" % (relays, os.path.relpath(path, root) if path.startswith(root) else path))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
