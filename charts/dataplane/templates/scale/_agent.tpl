{{/*
Fails the render when Scale's agent cannot reach its model as configured, so a bad setting stops
the install instead of a pod that fails at startup. tests/test-scale-guards.sh checks each case.
Mirrors operator/deploy/helm/templates/scale/_agent.tpl in unionai/cloud.
*/}}
{{- define "scale.agent.modelGuards" -}}
{{- $agent := .Values.scale.agent }}
{{- $model := $agent.model }}
{{- $provider := $model.provider | default "openai" }}
{{- if not (has $provider (list "anthropic" "openai")) }}
{{- fail (printf "scale.agent.model.provider must be anthropic or openai, not %q" $provider) }}
{{- end }}
{{- /* With a secret store, people can set the model and its key in the console instead. */}}
{{- $console := include "scale.agent.modelFromConsole" . }}
{{- if and (eq $provider "anthropic") (not $model.apiKeySecret.name) (not $console) }}
{{- fail "scale.agent.model.provider anthropic needs scale.agent.model.apiKeySecret.name: a secret in the release namespace holding an Anthropic API key, or a secret store (proxy.secretManager) so people can set the key in the console" }}
{{- end }}
{{- if and (eq $provider "openai") (not $model.baseURL) (not $console) }}
{{- fail "scale.agent.model.provider openai needs scale.agent.model.baseURL: an LLM gateway or a local OpenAI-compatible endpoint, or a secret store (proxy.secretManager) so people can set it in the console" }}
{{- end }}
{{- if not (has ($model.effort | default "") (list "" "low" "medium" "high" "xhigh" "max")) }}
{{- fail (printf "scale.agent.model.effort must be low, medium, high, xhigh, max or empty, not %q" $model.effort) }}
{{- end }}
{{- if and (hasKey $agent "maxScale") (lt (int $agent.maxScale) 1) }}
{{- fail (printf "scale.agent.maxScale must be 1 or more, not %v" $agent.maxScale) }}
{{- end }}
{{- $minScale := $agent.minScale | default 0 }}
{{- if or (ne (toString $minScale) (toString (int $minScale))) (lt (int $minScale) 0) }}
{{- fail (printf "scale.agent.minScale must be a whole number, 0 or more, not %v" $minScale) }}
{{- end }}
{{- if gt (int $minScale) (int ($agent.maxScale | default 1)) }}
{{- fail (printf "scale.agent.minScale must be at most scale.agent.maxScale (%v), not %v" ($agent.maxScale | default 1) $minScale) }}
{{- end }}
{{- $np := $agent.networkPolicy }}
{{- $egress := $np.egress | default dict }}
{{- if $egress.enabled }}
{{- if not $np.enabled }}
{{- fail "scale.agent.networkPolicy.egress.enabled needs scale.agent.networkPolicy.enabled: egress is part of that policy" }}
{{- end }}
{{- if not $egress.controlPlaneCIDRs }}
{{- fail "scale.agent.networkPolicy.egress needs controlPlaneCIDRs: the addresses of the control plane host (global.CONTROLPLANE_HOST), where the agent reads runs" }}
{{- end }}
{{- if $console }}
{{- /* People may pick either provider in the console: allow what they may pick. */}}
{{- if and (not $egress.model) (not $egress.anthropicCIDRs) }}
{{- fail "scale.agent.networkPolicy.egress needs anthropicCIDRs or model rules for the model people set in the console" }}
{{- end }}
{{- else }}
{{- if and (include "scale.agent.modelEgressFromValues" .) (not $egress.model) }}
{{- fail "scale.agent.networkPolicy.egress needs model rules for the model endpoint at scale.agent.model.baseURL" }}
{{- end }}
{{- if and (eq $provider "anthropic") (not $model.baseURL) (not $egress.anthropicCIDRs) }}
{{- fail "scale.agent.networkPolicy.egress needs anthropicCIDRs for the anthropic provider" }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
"true" when the model endpoint's egress comes from networkPolicy.egress.model rather than a
built-in rule: any openai endpoint, or a proxy at baseURL in front of the Anthropic API.
*/}}
{{- define "scale.agent.modelEgressFromValues" -}}
{{- $model := .Values.scale.agent.model }}
{{- if or (ne ($model.provider | default "openai") "anthropic") $model.baseURL -}}
true
{{- end -}}
{{- end -}}

{{/*
"true" when the agent takes the model people save in the console (Scale > Settings > Agent): the
settings the operator proxy saves in this cluster's secret store (scale__<org>__agent-model, out
of tasks' reach). Off when these values mount a key or gateway headers (they decide then), or when
the proxy has no secret store (config.proxy.smConfig.enabled, from proxy.secretManager.enabled),
since it would have nowhere to save them.
*/}}
{{- define "scale.agent.modelFromConsole" -}}
{{- $model := .Values.scale.agent.model }}
{{- $store := tpl (toString (dig "proxy" "smConfig" "enabled" false (.Values.config | default dict))) . }}
{{- if and (not $model.apiKeySecret.name) (not $model.headersSecret.name) (eq $store "true") -}}
true
{{- end -}}
{{- end -}}

{{/*
"true" when the agent takes the console's model settings but its network policy lets it reach only
the Anthropic API: egress is on and scale.agent.networkPolicy.egress.model adds no other endpoint.
The operator proxy then refuses any other model endpoint in SetAgentModel (agent.anthropicOnly), so a
person cannot save one the agent could not reach.
*/}}
{{- define "scale.agent.anthropicOnly" -}}
{{- $np := .Values.scale.agent.networkPolicy }}
{{- $egress := $np.egress | default dict }}
{{- if and (include "scale.agent.modelFromConsole" .) $np.enabled $egress.enabled (not $egress.model) -}}
true
{{- end -}}
{{- end -}}
