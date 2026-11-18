#!/usr/bin/env bash
# Detect the build/test technologies in a repo so optimize-build loads only the matching stack references.
# Usage: detect-stack.sh [repo-dir]
# Output: one line per technology: <key>\t<stack reference or "-">\t<evidence (the 3 shallowest paths)>
# A "-" reference means: detected, but no stack file yet — use the generic lane references.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")/../references/stack" 2>/dev/null && pwd || true)"
cd "${1:-.}"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  ALL=$(git ls-files --cached --others --exclude-standard)
else
  ALL=$(find . -type f \
      -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/target/*' \
      -not -path '*/.venv/*' -not -path '*/venv/*' -not -path '*/vendor/*' \
      -not -path '*/build/*' -not -path '*/dist/*' -not -path '*/.gradle/*' | sed 's|^\./||')
fi

shallow3() { # stdin: paths -> the 3 shallowest, comma-joined (root configs first)
  awk '{ n = gsub("/", "/"); print n "\t" $0 }' | sort -n -s -k1,1 | cut -f2- | head -3 | paste -sd, -
}

emit() { # key evidence
  local ref="-"
  if [ -n "$STACK_DIR" ] && [ -f "$STACK_DIR/$1.md" ]; then ref="references/stack/$1.md"; fi
  printf '%s\t%s\t%s\n' "$1" "$ref" "$2"
}

by_path() { # key ERE-on-path
  local m
  m=$(printf '%s\n' "$ALL" | grep -E "$2" | shallow3 || true)
  if [ -n "$m" ]; then emit "$1" "$m"; fi
}

by_dep() { # key npm-package — any package.json that lists it
  local m
  m=$(printf '%s\n' "$ALL" | grep -E '(^|/)package\.json$' | tr '\n' '\0' \
      | xargs -0 grep -l -E "\"$2\"[[:space:]]*:" 2>/dev/null | shallow3 || true)
  if [ -n "$m" ]; then emit "$1" "$m (dep $2)"; fi
}

by_ci() { # key ERE-on-workflow-content
  local m
  m=$(printf '%s\n' "$ALL" | grep -E '^\.github/workflows/[^/]+\.ya?ml$' | tr '\n' '\0' \
      | xargs -0 grep -l -E "$2" 2>/dev/null | shallow3 || true)
  if [ -n "$m" ]; then emit "$1" "$m (ci)"; fi
}

{
  by_path docker     '(^|/)(Dockerfile[^/]*|[^/]*\.Dockerfile|Containerfile|(docker-)?compose[^/]*\.ya?ml)$'
  by_ci   docker     'docker/build-push-action|docker (buildx )?build'
  by_path turbo      '(^|/)turbo\.json$'
  by_path nx         '(^|/)nx\.json$'
  by_path vitest     '(^|/)vitest\.(config|workspace)\.[cm]?[jt]s$'
  by_dep  vitest     'vitest'
  by_path jest       '(^|/)jest\.config\.([cm]?[jt]s|json)$'
  by_dep  jest       'jest'
  by_path playwright '(^|/)playwright(-ct)?\.config\.[cm]?[jt]s$'
  by_dep  playwright '@playwright/test'
  by_path typescript '(^|/)tsconfig[^/]*\.json$'
  by_path lint       '(^|/)(eslint\.config\.[cm]?[jt]s|\.eslintrc[^/]*|biome\.jsonc?|\.?oxlintrc\.jsonc?|oxlint\.config\.[cm]?[jt]s)$'
  by_dep  lint       'oxlint'
  by_dep  lint       'eslint'
  by_dep  lint       '@biomejs/biome'
  by_path node-pm    '(^|/)(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb?)$'
  by_path nextjs     '(^|/)next\.config\.[cm]?[jt]s$'
  by_path vite       '(^|/)vite\.config\.[cm]?[jt]s$'
  by_path python     '(^|/)(pyproject\.toml|uv\.lock|poetry\.lock|Pipfile(\.lock)?|setup\.(py|cfg)|pytest\.ini|tox\.ini|noxfile\.py|conftest\.py|requirements[^/]*\.txt)$'
  by_path go         '(^|/)go\.(mod|work)$'
  by_path rust       '(^|/)Cargo\.(toml|lock)$'
  by_path gradle     '(^|/)((build|settings)\.gradle(\.kts)?|gradlew|gradle\.properties)$'
  by_path maven      '(^|/)(pom\.xml|mvnw|\.mvn/[^/]+)$'
  # jvm = test-runtime costs shared by Gradle and Maven projects (JUnit, Spring, Testcontainers)
  by_path jvm        '(^|/)(pom\.xml|(build|settings)\.gradle(\.kts)?)$'
} | awk -F'\t' '!seen[$1]++'
