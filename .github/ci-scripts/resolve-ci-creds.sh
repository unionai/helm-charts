#!/usr/bin/env bash
# Resolve the CI-identity credentials for a func-v2 cloud leg from
# HELM_CHARTS_CI_FUNCTEST + the per-cloud secret store, and export them (masked)
# to $GITHUB_ENV for the functional-tests step. Keeps the workflow's func-v2 step thin.
#
#   resolve-ci-creds.sh <topology/cloud>
#
# Requires env FUNCTEST (the HELM_CHARTS_CI_FUNCTEST JSON) and an authenticated
# per-cloud CLI (the leg's kubeconfig step + the AWS ci_deployer step handle that).
# Writes CONTROL_PLANE_URL / ORG_NAME / CLUSTER_NAME / FLYTE_API_KEY /
# FUNCTIONAL_ARGS to $GITHUB_ENV (the same contract the k3d creds step
# emits, consumed by the shared setup-routing + functional-tests steps).
set -euo pipefail
leg="${1:?leg (topology/cloud)}"
: "${FUNCTEST:?FUNCTEST env (HELM_CHARTS_CI_FUNCTEST) required}"
: "${GITHUB_ENV:?GITHUB_ENV required (run in GitHub Actions)}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cfg=$(jq -c --arg k "$leg" '.[$k]' <<<"$FUNCTEST")
[ "$cfg" != "null" ] && [ -n "$cfg" ] || { echo "::error::no HELM_CHARTS_CI_FUNCTEST entry for $leg"; exit 1; }
get() { jq -r --arg f "$1" '.[$f] // ""' <<<"$cfg"; }
host=$(get endpoint); org=$(get org); cluster=$(get cluster_name)
secret_cloud=$(get secret_cloud); secret_ref=$(get secret_ref)
client_id=$(get client_id); skip_app=$(get skip_app)

# Fetch the CI-identity secret via the active per-cloud deployer identity.
case "$secret_cloud" in
  aws)   secret=$(aws secretsmanager get-secret-value --region us-east-2 \
                   --secret-id "$secret_ref" --query SecretString --output text) ;;
  gcp)   secret=$(gcloud secrets versions access latest \
                   --project "$(get gcp_project)" --secret "$secret_ref") ;;
  azure) secret=$(az keyvault secret show \
                   --vault-name "$(get azure_vault_name)" --name "$secret_ref" --query value -o tsv) ;;
  *) echo "::error::unknown secret_cloud $secret_cloud"; exit 1 ;;
esac
echo "::add-mask::$secret"

api_key=$("$here/build-api-key.sh" "$host" "$client_id" "$secret" "$org")
echo "::add-mask::$api_key"

# selfhosted has no app serving -> skip verify_app; all other standing legs run
# the full suite (k3d runs the full suite incl. best-effort logs).
functional_args=""
[ "$skip_app" = "true" ] && functional_args="--skip-app"

{
  echo "CONTROL_PLANE_URL=https://$host"
  echo "ORG_NAME=$org"
  echo "CLUSTER_NAME=$cluster"
  echo "FLYTE_API_KEY=$api_key"
  echo "FUNCTIONAL_ARGS=$functional_args"
} >> "$GITHUB_ENV"
echo "resolved CI creds for $leg (CI identity: ${client_id:-cicd})"
