{{/*
Connection helpers for the data-plane → control-plane path.

Single source of truth for the canonical CP endpoint expression and TLS
posture. Consumers (`config.admin.admin`, `config.catalog.catalog-cache`,
`config.k8s.plugins.k8s.default-env-vars`, `config.union.connection`,
`clusterresourcesync.config.union.connection`, etc.) reference these
helpers so the host, port, and TLS settings stay in sync across the chart.

Single control-plane host interface:
  CONTROLPLANE_HOST           bare CP hostname (no scheme, no port). The one host
                              global; everything derives from it.
  DEPRECATED fallbacks (still honored for backward compatibility; migrate to
  CONTROLPLANE_HOST): top-level .Values.host and global.UNION_CONTROL_PLANE_HOST.
  One of the three must be set or render fails.

The gRPC endpoint is always `dns:///<host>` — the port is omitted, so grpc
(dns resolver) and Connect (https) both default to 443. There is no separate
endpoint or queue-endpoint global. Authless / direct-service routing is
configured explicitly via `config.union.connection` + the auth toggles (see
examples/values.authless.yaml), not via a host override.
*/}}

{{- define "dataplane.cp.host" -}}
{{- $cp      := tpl (default "" .Values.global.CONTROLPLANE_HOST) . -}}
{{- $host    := tpl (default "" .Values.host) . -}}
{{- $legacy  := tpl (default "" .Values.global.UNION_CONTROL_PLANE_HOST) . -}}
{{- required "A control plane host is required: set global.CONTROLPLANE_HOST (the deprecated .Values.host and global.UNION_CONTROL_PLANE_HOST are still honored)" (coalesce $cp $host $legacy) -}}
{{- end -}}

{{- define "dataplane.cp.endpoint" -}}
{{- printf "dns:///%s" (include "dataplane.cp.host" .) -}}
{{- end -}}

{{/*
TLS posture for CP nginx (terminates TLS on 443 regardless of topology;
selfhosted cert is self-signed). Per-consumer YAML literals — bool field
spelling varies across config schemas (insecure vs insecure-skip-verify
vs insecureSkipVerify) and YAML/Go-config bool coercion through helm
template strings is fragile, so callers write the booleans inline.
*/}}

{{/*
Self-reporting helpers for the data-plane → control-plane Heartbeat /
UpdateStatus.connection_config field. The operator reads the rendered
JSON file at startup and ships it on every UpdateStatus so the CP can
dial back without anyone having to admin-set DataplaneIngressURL.

Override surface (.Values.updateStatus.connectionConfig):
  enabled             opt in to self-reporting. Off by default so the chart
                      stays compatible with operator images that predate the
                      connection_config support — they receive no config key,
                      ConfigMap, or mount they can't consume.
  host                bare DP-reachable hostname (no scheme, no port).
                      Empty falls back to .Values.ingress.host — the
                      dataplane's own ingress hostname — so most installs
                      don't need to set this explicitly.
  insecure            CP dials with plain HTTP/2 (no TLS) when true
  insecureSkipVerify  CP skips cert validation (self-signed cert envs)

The operator self-reports the bare host (dataplane.dp.host); the control
plane builds the http(s)://host URL from it. Empty host renders no
connection_config resource — callers gate emission on this.

dataplane.connectionConfig.emit is the single gate every consumer keys off:
it returns the resolved host only when self-reporting is both enabled and
resolvable, empty otherwise — so an opt-out or missing host renders no
connection_config resource, config key, volume, or mount.
*/}}

{{- define "dataplane.dp.host" -}}
{{- $explicit := tpl (default "" .Values.updateStatus.connectionConfig.host) . -}}
{{- $derived := tpl (default "" .Values.ingress.host) . -}}
{{- default $derived $explicit -}}
{{- end -}}

{{- define "dataplane.connectionConfig.emit" -}}
{{- if .Values.updateStatus.connectionConfig.enabled -}}
{{- include "dataplane.dp.host" . -}}
{{- end -}}
{{- end -}}
