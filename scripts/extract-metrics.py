#!/usr/bin/env python3
"""Extract metric names from Grafana dashboards and PrometheusRule templates.

Produces a sorted, deduplicated YAML manifest of all metrics referenced in
shipped dashboards and PrometheusRule CRDs. This manifest makes metric
additions, removals, and renames visible in PR diffs.

Usage:
    python scripts/extract-metrics.py > metrics-manifest.yaml
"""

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

DASHBOARD_FILES = [
    REPO_ROOT / "charts/controlplane/dashboards/union-controlplane-overview.json",
    REPO_ROOT / "charts/dataplane/dashboards/union-dataplane-overview.json",
]

PROMETHEUSRULE_FILES = [
    REPO_ROOT / "charts/controlplane/templates/monitoring/prometheusrule.yaml",
    REPO_ROOT / "charts/dataplane/templates/monitoring/prometheusrule.yaml",
]

# Metric name pattern: prometheus metric names are [a-zA-Z_:][a-zA-Z0-9_:]*
# We look for names used in PromQL expressions.
METRIC_NAME_RE = re.compile(r'[a-zA-Z_:][a-zA-Z0-9_:]*')

# Known non-metric tokens to exclude (PromQL functions, keywords, labels, etc.)
EXCLUDE = {
    # PromQL functions
    'abs', 'absent', 'avg', 'avg_over_time', 'bottomk', 'ceil', 'changes',
    'clamp', 'clamp_max', 'clamp_min', 'count', 'count_over_time', 'count_values',
    'day_of_month', 'day_of_week', 'days_in_month', 'delta', 'deriv', 'exp',
    'floor', 'group', 'histogram_quantile', 'holt_winters', 'hour', 'idelta',
    'increase', 'irate', 'label_join', 'label_replace', 'last_over_time', 'ln',
    'log2', 'log10', 'max', 'max_over_time', 'min', 'min_over_time', 'minute',
    'month', 'predict_linear', 'quantile', 'quantile_over_time', 'rate', 'resets',
    'round', 'scalar', 'sgn', 'sort', 'sort_desc', 'sqrt', 'stddev',
    'stddev_over_time', 'stdvar', 'stdvar_over_time', 'sum', 'sum_over_time',
    'time', 'timestamp', 'topk', 'vector', 'year',
    # PromQL aggregation modifiers / keywords
    'by', 'without', 'on', 'ignoring', 'group_left', 'group_right', 'bool',
    'offset', 'and', 'or', 'unless',
    # Common label names (not metrics)
    'namespace', 'pod', 'container', 'deployment', 'service', 'code', 'status',
    'host', 'path', 'le', 'quantile', 'job', 'instance', 'grpc_service',
    'grpc_method', 'grpc_code', 'type', 'op', 'worker_name', 'org',
    'cluster_name', 'cluster', 'operation', 'phase', 'error_type',
    'error_source', 'identity_type', 'action', 'subsystem', 'name',
    # Grafana template variables / constants
    '__rate_interval', '__name__', '__NAMESPACE__',
    # Short tokens that are label values not metrics
    'OK', 'Canceled', 'NotFound', 'Succeeded',
}

# Minimum length to be considered a metric (avoids label values like "5m")
MIN_METRIC_LEN = 4


def extract_from_dashboard(filepath: Path) -> set[str]:
    """Extract metric names from Grafana dashboard JSON."""
    metrics = set()
    with open(filepath) as f:
        dashboard = json.load(f)

    def walk_panels(panels):
        for panel in panels:
            # Nested panels (collapsed rows)
            if 'panels' in panel:
                walk_panels(panel['panels'])
            for target in panel.get('targets', []):
                expr = target.get('expr', '')
                if not expr:
                    continue
                for token in METRIC_NAME_RE.findall(expr):
                    if _is_metric_name(token):
                        metrics.add(token)

    walk_panels(dashboard.get('panels', []))
    return metrics


def _is_metric_name(token: str) -> bool:
    """Return True if a token looks like a Prometheus metric name."""
    if token in EXCLUDE or len(token) < MIN_METRIC_LEN:
        return False
    if token.startswith('$') or token.startswith('.'):
        return False
    if token.replace('_', '').isdigit():
        return False
    if token[0].isupper():  # Capitalized words are English text, not metrics
        return False
    if token.startswith(':') or token.startswith('_') or token.endswith(':'):
        return False  # Fragment, not a full metric name
    if ':' not in token and '_' not in token:
        return False  # Real metrics have : or _
    return True


def _extract_promql_metrics(expr: str, metrics: set) -> None:
    """Extract metric names from a PromQL expression string."""
    for token in METRIC_NAME_RE.findall(expr):
        if _is_metric_name(token):
            metrics.add(token)


def extract_from_prometheusrule(filepath: Path) -> dict:
    """Extract recording rule names, alert names, and source metrics from PrometheusRule templates."""
    text = filepath.read_text()
    recording_rules = set()
    alerts = set()
    source_metrics = set()

    # Extract recording rule names
    for m in re.finditer(r'record:\s*(\S+)', text):
        recording_rules.add(m.group(1))

    # Extract alert names
    for m in re.finditer(r'alert:\s*(\S+)', text):
        alerts.add(m.group(1))

    # Extract metrics from expr: blocks only (skip annotations, labels, etc.)
    in_expr = False
    in_skip_block = False
    for line in text.splitlines():
        stripped = line.strip()

        # Skip annotation and label blocks entirely
        if stripped.startswith('annotations:') or stripped.startswith('summary:') or stripped.startswith('description:'):
            in_skip_block = True
            in_expr = False
            continue
        if stripped.startswith('labels:') and not stripped.startswith('labels.'):
            in_skip_block = True
            in_expr = False
            continue

        if stripped.startswith('expr:'):
            in_skip_block = False
            in_expr = True
            rest = stripped[len('expr:'):].strip().lstrip('|').strip()
            if rest:
                _extract_promql_metrics(rest, source_metrics)
        elif stripped.startswith('record:') or stripped.startswith('alert:') or stripped.startswith('for:'):
            in_expr = False
            in_skip_block = False
        elif in_expr and not in_skip_block:
            if stripped and not stripped.startswith('#'):
                _extract_promql_metrics(stripped, source_metrics)
            if not stripped:
                in_expr = False

    # Remove recording rule names and alert names from source metrics
    source_metrics -= recording_rules
    source_metrics -= alerts
    # Remove Helm template artifacts and non-metric tokens
    source_metrics = {m for m in source_metrics
                      if not m.startswith('Values')
                      and not m.startswith('Release')
                      and ':' in m or '_' in m}

    return {
        'recording_rules': recording_rules,
        'alerts': alerts,
        'source_metrics': source_metrics,
    }


def plane_name(filepath: Path) -> str:
    if 'controlplane' in str(filepath):
        return 'controlplane'
    elif 'dataplane' in str(filepath):
        return 'dataplane'
    return filepath.stem


def emit_yaml(data: dict) -> str:
    """Emit clean YAML without external dependencies."""
    lines = [
        "# Auto-generated metrics manifest — do not edit manually.",
        "# Regenerate with: make generate-metrics-manifest",
        "#",
        "# This file tracks all metrics referenced in shipped Grafana dashboards",
        "# and PrometheusRule CRDs. Changes here signal that the metrics glossary",
        "# in unionai-docs may need updating.",
        "#",
        "# Docs: unionai-docs/content/deployment/selfhosted/monitoring/metrics-glossary.md",
        "",
    ]

    for plane in ('controlplane', 'dataplane'):
        lines.append(f"{plane}:")
        pd = data[plane]

        lines.append("  dashboard_metrics:")
        for m in sorted(pd.get('dashboard_metrics', [])):
            lines.append(f"    - {m}")

        lines.append("  recording_rules:")
        for m in sorted(pd.get('recording_rules', [])):
            lines.append(f"    - {m}")

        lines.append("  alerts:")
        for m in sorted(pd.get('alerts', [])):
            lines.append(f"    - {m}")

        lines.append("")

    return '\n'.join(lines)


def main():
    data = {}

    for df in DASHBOARD_FILES:
        plane = plane_name(df)
        metrics = extract_from_dashboard(df)
        data.setdefault(plane, {})['dashboard_metrics'] = metrics

    for pf in PROMETHEUSRULE_FILES:
        plane = plane_name(pf)
        result = extract_from_prometheusrule(pf)
        data.setdefault(plane, {})
        data[plane]['recording_rules'] = result['recording_rules']
        data[plane]['alerts'] = result['alerts']
        # Merge source metrics into dashboard metrics
        data[plane].setdefault('dashboard_metrics', set())
        data[plane]['dashboard_metrics'] |= result['source_metrics']

    print(emit_yaml(data))


if __name__ == '__main__':
    main()
