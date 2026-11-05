#!/usr/bin/env bash
# Tests for scripts/check-route-relay-host.py (hugmesh-generator#622): every
# host-predicated route in deploy/configmap.yaml that relays to another gateway
# must carry the PreserveHostHeader filter.
#
# Runs the checker against the real deploy/configmap.yaml (must pass), then
# against corrupted copies (each must fail). Every copy is checked to really
# differ from the original before the checker runs, so a mutation that silently
# matched nothing cannot pass as a caught defect. Needs bash, python3 and PyYAML;
# no network. Run by the release workflow's version job; run locally with:
# bash scripts/test-route-relay-host.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
checker="$here/check-route-relay-host.py"
configmap="$root/deploy/configmap.yaml"

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/route-relay-host-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

# expect <want-exit> <label> <file> [<fixed text the output must contain>]
# The text pins WHY the checker failed, so a control cannot pass on a different
# failure (for example the "no relay at all" branch).
expect() {
  local want label file text got
  want="$1"
  label="$2"
  file="$3"
  text="${4:-}"
  got=0
  python3 "$checker" "$file" >"$work/out" 2>&1 || got=$?
  if [ "$got" -ne "$want" ]; then
    bad "$label: wanted exit $want, got $got"
    sed 's/^/     | /' "$work/out"
  elif [ -n "$text" ] && ! grep -F -- "$text" "$work/out" >/dev/null; then
    bad "$label: exit $got as wanted, but the output does not say: $text"
    sed 's/^/     | /' "$work/out"
  else
    ok "$label (exit $got)"
  fi
}

# mutate <name> <python expression over s>: writes $work/<name>.yaml from the
# real configmap; refuses (counts a failure) if the result equals the original.
mutate() {
  local name expr
  name="$1"
  expr="$2"
  if python3 - "$configmap" "$work/$name.yaml" "$expr" <<'PY'
import re, sys
src, dst, expr = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src, encoding="utf-8").read()
FILTER = ("                  filters:\n"
          "                    - PreserveHostHeader\n")
# expr is one of the fixed mutation strings written in this script, never input.
out = eval(expr, {"s": s, "FILTER": FILTER, "re": re})
open(dst, "w", encoding="utf-8").write(out)
sys.exit(0 if out != s else 1)
PY
  then
    return 0
  fi
  bad "mutation $name did not change the file (it matched nothing)"
  return 1
}

python3 -c 'import yaml' || { echo "FAIL PyYAML is not installed; cannot run" >&2; exit 1; }

# --- the real file -------------------------------------------------------------
expect 0 "deploy/configmap.yaml: every gateway relay preserves Host" "$configmap"

# --- negative controls ---------------------------------------------------------
# (a) the filter deleted from headscale-forward: the #622 defect itself.
if mutate no-filter 's.replace(FILTER, "", 1)'; then
  expect 1 "headscale-forward without PreserveHostHeader is caught" "$work/no-filter.yaml" \
    "route 'headscale-forward' relays"
fi

# (b) the filter moved to a different route: a file-wide text search would still
#     pass, the per-route check must not.
if mutate moved-filter 's.replace(FILTER, "", 1).replace("                    - Host=mastodon.hugmesh.net\n                - id: matrix-api", "                    - Host=mastodon.hugmesh.net\n" + FILTER + "                - id: matrix-api", 1)'; then
  expect 1 "PreserveHostHeader on another route does not count" "$work/moved-filter.yaml" \
    "route 'headscale-forward' relays"
fi

# (c) the relay route removed entirely: the check must not pass vacuously.
if mutate no-relay 're.sub(r"                - id: headscale-forward\n(?:                  .*\n|                    .*\n)*?(?=                - id: )", "", s, count=1)'; then
  expect 1 "no gateway relay route at all fails (not vacuous)" "$work/no-relay.yaml" \
    "found no host-predicated gateway-to-gateway route"
fi

# (d) a second relay (another -gateway target, https, Host + Path) without the
#     filter: the rule is general, not tied to the headscale-forward id.
if mutate second-relay 's.replace("                - id: mastodon-oauth\n", "                - id: fe-relay\n                  uri: https://hugmesh-fe-gateway.hugmesh-frontend.svc.cluster.local:8443\n                  predicates:\n                    - Host=www.hugmesh.net\n                    - Path=/x/**\n                - id: mastodon-oauth\n", 1)'; then
  expect 1 "any other host-predicated gateway relay without the filter is caught" "$work/second-relay.yaml" \
    "route 'fe-relay' relays Host=www.hugmesh.net"
fi

# (e) the relay written in the long (name/args) form without the filter.
if mutate long-form 's.replace(FILTER, "", 1).replace("                    - Host=scale.hugmesh.net\n", "                    - name: Host\n                      args:\n                        patterns: scale.hugmesh.net\n", 1)'; then
  expect 1 "long-form Host predicate without the filter is caught" "$work/long-form.yaml" \
    "route 'headscale-forward' relays Host=scale.hugmesh.net"
fi

# (e2) the same long-form Host predicate WITH the filter must pass: it is only
#      counted as a relay (rather than skipped) if the long form is understood.
if mutate long-form-ok 's.replace("                    - Host=scale.hugmesh.net\n", "                    - name: Host\n                      args:\n                        patterns: scale.hugmesh.net\n", 1)'; then
  expect 0 "long-form Host predicate with the filter is accepted" "$work/long-form-ok.yaml"
fi

# (f) positive control for the long form of the filter itself.
if mutate long-filter 's.replace(FILTER, "                  filters:\n                    - name: PreserveHostHeader\n", 1)'; then
  expect 0 "long-form PreserveHostHeader filter is accepted" "$work/long-filter.yaml"
fi

# (g) the routes key gone, or the file missing: an error, not a pass.
if mutate no-routes-key 's.replace("  application-routes.yml: |", "  other.yml: |", 1)'; then
  expect 2 "ConfigMap without application-routes.yml is an error" "$work/no-routes-key.yaml"
fi
expect 2 "missing file is an error" "$work/does-not-exist.yaml"

echo
echo "relay-host tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
