# knative-operator — Release Notes

`appVersion` tracks the Knative Operator release the chart deploys, not the
control-plane / data-plane image tag.

## 2026.10.0

The `knative-operator` Deployment and its pods carry `platform.union.ai/component:
knative-operator`, the label the Union operator's cluster snapshot discovers Union
workloads by (see `charts/CONVENTIONS.md`). No values change; the selector is untouched.
`appVersion` stays `1.16.0`.
