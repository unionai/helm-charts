"""
Grafana as a Flyte App — per-dataplane observability.

Runs Grafana inside a dataplane cluster, anonymous, serving the shipped v1/v2 + Karpenter
dataplane dashboards over that cluster's Prometheus. Access is gated by the zero-trust
app-serving edge (requires_auth=True); Grafana itself has no login, so the auth boundary is
the app gateway, not Grafana.

The dashboards under grafana/dashboards/ are synced verbatim from the sibling
charts/dataplane chart (sync_dashboards.py / `make sync-app-dashboards`) so the app and the
shipped dashboard ConfigMaps never drift.

DATASOURCE_MODE selects how the single Prometheus datasource authenticates. The pod's cloud
identity comes from the worker namespace's default ServiceAccount (WIF on GKE, IRSA on EKS,
Workload Identity on AKS) — no secrets are mounted.

    in-cluster  (default)  no auth; co-located kube-prometheus-stack
    gmp-frontend           no auth; DS_PROM_URL points at the in-cluster GMP frontend proxy
    amp                    AWS AMP via SigV4 using the pod IRSA identity (set AWS_REGION)
    azure                  Azure Monitor Managed Prometheus via the pod Workload Identity

Serve (flags BEFORE the file; app env var is `grafana`; omit --follow — the log tail errors
but the deploy still succeeds):

    flyte serve --project <proj> --domain <domain> app.py grafana
"""
import os
from pathlib import Path

import flyte
from flyte.app import AppEnvironment, Domain, Scaling

HERE = Path(__file__).parent

DATASOURCE_MODE = os.environ.get("DATASOURCE_MODE", "in-cluster")
_DS_FILE = {
    "in-cluster": "mode-in-cluster.yaml",
    "gmp-frontend": "mode-in-cluster.yaml",
    "amp": "mode-amp.yaml",
    "azure": "mode-azure.yaml",
}[DATASOURCE_MODE]

PROM_URL = os.environ.get(
    "PROMETHEUS_URL", "http://prometheus-operated.dataplane.svc.cluster.local:9090"
)
AWS_REGION = os.environ.get("AWS_REGION", "us-east-2")

# Optional stable subdomain. Empty (default) -> omit so the platform assigns the default.
APP_SUBDOMAIN = os.environ.get("APP_SUBDOMAIN", "").strip()

image = (
    flyte.Image.from_base("grafana/grafana:11.3.0")
    .clone(extendable=True, name="grafana-dataplane")
    .with_source_folder(
        HERE / "grafana" / "provisioning" / "dashboards",
        "/etc/grafana/provisioning/dashboards",
    )
    .with_source_file(
        HERE / "grafana" / "provisioning" / "datasources" / _DS_FILE,
        "/etc/grafana/provisioning/datasources/datasources.yaml",
    )
    .with_source_folder(HERE / "grafana" / "dashboards", "/var/lib/grafana/dashboards")
)

grafana = AppEnvironment(
    name=os.environ.get("APP_NAME", "grafana"),
    description="Read-only Grafana over this dataplane cluster's Prometheus.",
    image=image,
    port=8080,
    command=["/run.sh"],
    requires_auth=True,
    domain=Domain(subdomain=APP_SUBDOMAIN) if APP_SUBDOMAIN else Domain(),
    env_vars={
        "GF_SERVER_HTTP_PORT": "8080",
        "GF_AUTH_ANONYMOUS_ENABLED": "true",
        # Least privilege. The app edge authorizes WHO can open the app, not what they can do
        # inside Grafana, so every anonymous visitor shares this role. Viewer keeps the
        # datasource un-editable (no proxy re-point / SSRF). Set to "Admin" only if you are OK
        # with any identity that can authenticate to your Union host having Admin here.
        "GF_AUTH_ANONYMOUS_ORG_ROLE": os.environ.get("GF_ANON_ROLE", "Viewer"),
        "GF_AUTH_DISABLE_LOGIN_FORM": "true",
        "GF_AUTH_BASIC_ENABLED": "false",
        "GF_USERS_ALLOW_ORG_CREATE": "false",
        "GF_USERS_ALLOW_SIGN_UP": "false",
        "GF_PATHS_PROVISIONING": "/etc/grafana/provisioning",
        "DS_PROM_URL": PROM_URL,
        "DS_AWS_REGION": AWS_REGION,
        "GF_ANALYTICS_REPORTING_ENABLED": "false",
        "GF_ANALYTICS_CHECK_FOR_UPDATES": "false",
    },
    resources=flyte.Resources(cpu="500m", memory="512Mi"),
    scaling=Scaling(replicas=(1, 1)),
)

if __name__ == "__main__":
    flyte.init_from_config()
    flyte.serve(grafana)
