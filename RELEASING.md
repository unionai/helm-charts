# Releasing charts

This repo publishes charts to a Helm repository hosted on the `gh-pages` branch
(`https://unionai.github.io/helm-charts`). There are two channels:

| Channel | Workflow | Trigger | Marked "latest"? |
|---------|----------|---------|------------------|
| **Stable** | `.github/workflows/release.yaml` | a `charts/*/Chart.yaml` version change merged to `main` | yes |
| **Pre-release** (alpha/beta) | `.github/workflows/prerelease.yaml` | pushing a tag `<chart>-<version>` whose version has a SemVer pre-release suffix | no |

Both run [`chart-releaser`](https://github.com/helm/chart-releaser-action): it
packages each chart at its `Chart.yaml` `version:`, creates a GitHub Release +
tag (`<chart>-<version>`), and updates the shared Helm repo index. `skip_existing`
means only versions that aren't already released are published.

## Versioning

Stable charts use CalVer: `YYYY.M.PATCH`, e.g. `2026.6.9` — **no hyphen**.

A pre-release adds a SemVer-2 pre-release suffix to the *next* version:
`2026.6.10-alpha.0`, `2026.6.10-beta.1`. Helm sorts these below the
corresponding stable version and hides them from `helm pull` / `dependency
update` unless `--devel` is passed or the exact version is pinned.

## Cut a stable release

1. Bump the chart's `version:` in `charts/<chart>/Chart.yaml` (and regenerate
   snapshots: `make generate-expected`).
2. Open a PR and merge to `main`.
3. `release.yaml` publishes the chart and marks it latest.

## Cut a pre-release (alpha/beta)

Pre-releases are cut from a **tag**, not from `main` — so you can publish an
alpha/beta from a feature branch without touching the stable channel.

```bash
# 1. On your branch, set the pre-release version in the chart you're releasing:
#      charts/controlplane/Chart.yaml:  version: 2026.6.10-beta.0
git commit -am "controlplane 2026.6.10-beta.0"

# 2. Tag that commit <chart>-<version> and push the tag:
git tag controlplane-2026.6.10-beta.0
git push origin controlplane-2026.6.10-beta.0
```

`prerelease.yaml` packages the chart at the tagged commit, publishes a GitHub
**pre-release** (never "latest"), and adds it to the Helm repo index. Bump the
suffix (`-beta.1`, `-beta.2`, …) for each iteration.

### Consuming a pre-release

```bash
helm repo add union https://unionai.github.io/helm-charts
helm repo update
helm pull union/controlplane --devel                    # newest, including pre-releases
helm pull union/controlplane --version 2026.6.10-beta.0  # an exact pre-release
```

> Note: selfhosted/managed deployments pin this repo by **git ref** (via
> `revisions.yaml` in `unionai/cloud`), not by the Helm repo index — so for those
> consumers a pre-release tag is mainly a stable, named point to pin against.

## Promoting a pre-release to stable

When the pre-release is good, **drop the suffix** before merging to `main`:
set the version to the final `2026.6.10` (no `-beta`), then follow
[Cut a stable release](#cut-a-stable-release).

> ⚠️ **Never merge a `-alpha`/`-beta` version into `main`.** `release.yaml`
> fires on any `Chart.yaml` change to `main` and would publish that pre-release
> on the **stable, latest** channel. Always promote by removing the suffix first.
