# Knative Operator CRDs

Vendored from the previous Helm chart at
[`charts/knative-operator-crds`](../../charts/knative-operator-crds) (now
deprecated). The chart's source-of-truth was a multi-doc
`knative-crds.yaml` imported from
`https://github.com/knative/serving/releases/download/knative-v1.16.0/serving-crds.yaml`
plus the Knative Operator CRDs (`knativeservings`, `knativeeventings`); this
directory keeps the same content split into one file per CRD, with the
`argocd.argoproj.io/sync-options: ServerSideApply=true` annotation injected.

Required when App Serving is enabled — the operator consumes the
`knative.dev` and `operator.knative.dev` CRDs at runtime.

No `scripts/sync.sh` for now: upstream Knative ships these CRDs across two
projects (`knative/serving` + `knative/operator`) and the previous chart
hand-merged them. Edit the vendored files directly to add CRDs from a newer
release; if we adopt a strict sync workflow, add it then.
