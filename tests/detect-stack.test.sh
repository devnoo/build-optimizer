#!/usr/bin/env bash
# Checks that detect-stack.sh reports the right keys, and a stack reference for each, per fixture project.
# Usage: bash tests/detect-stack.test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/skills/optimize-build/scripts/detect-stack.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

mk() { mkdir -p "$TMP/$1/$(dirname "$2")"; printf '%s' "${3:-}" > "$TMP/$1/$2"; }

expect() { # fixture "space-separated keys in output order"
  local got
  got=$(bash "$SCRIPT" "$TMP/$1" | cut -f1 | paste -sd' ' -)
  if [ "$got" = "$2" ]; then echo "ok   $1: ${got:-<none>}"; else echo "FAIL $1: want '$2', got '$got'"; fail=1; fi
  if bash "$SCRIPT" "$TMP/$1" | cut -f2 | grep -qx -- '-'; then echo "FAIL $1: a key has no stack reference"; fail=1; fi
}

mk go go.mod;                 mk go cmd/app/main.go
mk rust Cargo.toml;           mk rust Cargo.lock
mk python pyproject.toml;     mk python uv.lock
mk gradle build.gradle.kts;   mk gradle gradlew
mk maven pom.xml;             mk maven .mvn/extensions.xml
mk node package-lock.json;    mk node tsconfig.json
mk node package.json '{"devDependencies":{"vitest":"^5","eslint":"^10","@playwright/test":"^1"}}'
mk docker Dockerfile;         mk docker compose.yaml
mk "with space" "sub dir/go.mod"
mk empty README.md
mk nested services/api/go.mod; mk nested services/web/package-lock.json; mk nested tools/gen/Cargo.toml

expect go "go"
expect rust "rust"
expect python "python"
expect gradle "gradle jvm"
expect maven "maven jvm"
expect node "vitest playwright typescript lint node-pm"
expect docker "docker"
expect "with space" "go"
expect empty ""
expect nested "node-pm go rust"

exit $fail
