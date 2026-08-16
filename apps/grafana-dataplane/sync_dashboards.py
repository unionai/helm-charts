#!/usr/bin/env python3
"""
Sync the Grafana app's dashboards from the charts/dataplane chart — source of truth.

The app serves the exact dashboards helm ships. Helm's dashboard-configmap replaces the
`__NAMESPACE__` token with the release namespace; here we replace it with the namespace that
runs union services (default `dataplane`, where propeller/leaseworker/operator live) so the
dashboards' namespace picker defaults there. The output is otherwise byte-identical to the
chart JSON, so drift is a `git diff` away.

Run from anywhere:  python3 sync_dashboards.py
Enforced in CI by:  make check-app-dashboards
"""
import argparse
from pathlib import Path

HERE = Path(__file__).parent
CHART = HERE.parent.parent / "charts" / "dataplane"

SOURCES = [
    CHART / "dashboards" / "union-dataplane-overview.json",
    CHART / "dashboards" / "union-dataplane-v1-overview.json",
    CHART / "files" / "dashboards" / "union-dataplane-karpenter.json",
    CHART / "files" / "dashboards" / "union-dataplane-slo.json",
]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--union-namespace",
        default="dataplane",
        help="namespace running union services; the dashboards' namespace picker defaults here",
    )
    args = ap.parse_args()
    out = HERE / "grafana" / "dashboards"
    out.mkdir(parents=True, exist_ok=True)
    for src in SOURCES:
        if not src.exists():
            raise SystemExit(f"source dashboard missing: {src}")
        text = src.read_text().replace("__NAMESPACE__", args.union_namespace)
        (out / src.name).write_text(text)
        print(f"wrote {out / src.name}  (__NAMESPACE__ -> {args.union_namespace})")


if __name__ == "__main__":
    main()
