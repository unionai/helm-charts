#!/usr/bin/env bash
#
# Stage 1 of the disclosure gate: mechanical scan of generated upgrade skills for
# content that must never reach a public repository.
#
# A clean scan is NECESSARY, NOT SUFFICIENT. Stage 2 is a human/agent read-through
# against references/disclosure-policy.md, which catches what a grep cannot.
#
# Usage:
#   ./scan-disclosure.sh charts/dataplane/upgrades/2026.8.3
#   ./scan-disclosure.sh charts/dataplane/upgrades/2026.8.3/SKILL.md
#
# Exit 0 = clean, exit 1 = findings.

set -uo pipefail

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  echo "usage: $0 <file-or-directory>" >&2
  exit 2
fi

if [[ -d "$TARGET" ]]; then
  mapfile -t FILES < <(find "$TARGET" -type f \( -name '*.md' -o -name '*.yaml' \))
else
  FILES=("$TARGET")
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "no files found under $TARGET" >&2
  exit 2
fi

findings=0

# Rules are TAB-delimited: name <TAB> regex <TAB> explanation.
# A tab is used because the regexes themselves contain "|" -- splitting on "|"
# silently truncates them to their first alternative, and grep then fails quietly.
RULES=(
  $'cloud-account-id\t\\b[0-9]{12}\\b\tAWS account ID'
  $'uuid\t\\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\b\tGUID (subscription/tenant/client ID)'
  $'ticket-id\t\\b(ENG[0-9]*|SE|AI|PII|FAB|OPS)-[0-9]{2,}\\b\tinternal ticket identifier'
  $'tracker-url\t(linear\\.app|notion\\.so|fathom\\.video|\\.slack\\.com)\tinternal tracker or chat URL'
  $'union-hostname\t[a-z0-9-]+\\.(hosted\\.)?unionai\\.cloud\tUnion-operated tenant hostname'
  $'private-registry\t[a-z0-9-]+\\.(dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com|azurecr\\.io)\taccount-specific container registry'
  $'gar-registry\t[a-z0-9-]+-docker\\.pkg\\.dev\taccount-specific container registry'
  $'gcp-sa-email\t[a-z0-9-]+@[a-z0-9-]+\\.iam\\.gserviceaccount\\.com\tservice account email'
  $'role-arn\tarn:aws:iam::[0-9]+:\tIAM role ARN'
  $'go-source-ref\t[a-z0-9_/-]+\\.go:[0-9]+\tsource file:line reference'
  $'internal-env\t\\b(dogfood|union-internal|selfserve-test)\\b\tinternal environment name'
  $'secretish\t(BEGIN [A-Z ]*PRIVATE KEY|client_?secret[[:space:]]*[:=]|password[[:space:]]*[:=][[:space:]]*[^[:space:]])\tpossible credential'
)

# Self-managed org slugs to flag.
#
# Deliberately NOT hardcoded: a list of Union's self-managed customers is itself the kind
# of thing this scan exists to protect, and this script may end up in a public repository.
#
# Supply it locally, and never commit it:
#   export UNION_ORG_SLUGS='acme|globex|initech'
# or create a .disclosure-orgs file next to this script, one slug per line.
INTERNAL_PATHS="${UNION_INTERNAL_PATHS:-}"
PATHS_FILE="$(dirname "${BASH_SOURCE[0]}")/.disclosure-paths"
if [[ -z "$INTERNAL_PATHS" && -f "$PATHS_FILE" ]]; then
  INTERNAL_PATHS=$(grep -vE '^\s*(#|$)' "$PATHS_FILE" | paste -sd'|' -)
fi

ORG_SLUGS="${UNION_ORG_SLUGS:-}"
ORG_FILE="$(dirname "${BASH_SOURCE[0]}")/.disclosure-orgs"
if [[ -z "$ORG_SLUGS" && -f "$ORG_FILE" ]]; then
  ORG_SLUGS=$(grep -vE '^\s*(#|$)' "$ORG_FILE" | paste -sd'|' -)
fi
if [[ -z "$ORG_SLUGS" ]]; then
  cat >&2 <<'WARN'
WARNING: no org-slug list configured, so customer names will NOT be flagged.
         This scan is materially weaker. Set UNION_ORG_SLUGS or create a
         .disclosure-orgs file next to this script (never commit either).
         Likewise UNION_INTERNAL_PATHS / .disclosure-paths for internal
         repository and service names.
WARN
fi

for f in "${FILES[@]}"; do
  for rule in "${RULES[@]}"; do
    IFS=$'\t' read -r name regex desc <<< "$rule"
    # Surface a broken rule loudly rather than letting it fail open.
    if ! printf '' | grep -qE "$regex" 2>/dev/null && [[ $? -gt 1 ]]; then
      echo "ERROR: rule '$name' has an invalid regex -- the scan is not trustworthy" >&2
      exit 2
    fi
    if hits=$(grep -nEI "$regex" "$f" 2>/dev/null); then
      echo "FINDING [$name] $desc"
      echo "  file: $f"
      sed 's/^/    /' <<< "$hits"
      echo
      findings=$((findings + 1))
    fi
  done

  if [[ -n "$ORG_SLUGS" ]] \
     && hits=$(grep -nEiI "(^|[^a-z0-9-])($ORG_SLUGS)([^a-z0-9-]|\$)" "$f" 2>/dev/null); then
    echo "FINDING [customer-name] organization slug"
    echo "  file: $f"
    sed 's/^/    /' <<< "$hits"
    echo
    findings=$((findings + 1))
  fi

  if [[ -n "$INTERNAL_PATHS" ]] \
     && hits=$(grep -nEI "(^|[^a-z0-9./-])($INTERNAL_PATHS)/" "$f" 2>/dev/null); then
    echo "FINDING [internal-repo-path] internal repository path"
    echo "  file: $f"
    sed 's/^/    /' <<< "$hits"
    echo
    findings=$((findings + 1))
  fi
done

if [[ $findings -gt 0 ]]; then
  cat <<'MSG'
--------------------------------------------------------------------------
Disclosure scan FAILED.

Fix the output, not the scan. See references/disclosure-policy.md, in
particular the rewrite table -- most findings become publishable when
restated as observable consequence rather than internal mechanism.

If a hit is genuinely a false positive (e.g. a placeholder that happens to
match a pattern), change the placeholder so it no longer matches.
--------------------------------------------------------------------------
MSG
  exit 1
fi

cat <<'MSG'
Disclosure scan clean.

Stage 1 (mechanical) passed. Stage 2 is still required: reread the output and
ask, for each paragraph, whether someone outside Union could have written it
from the public chart alone. See references/disclosure-policy.md.
MSG
