# Releasing charts

This repo publishes charts to a Helm repository hosted on the `gh-pages` branch
(`https://unionai.github.io/helm-charts`).

A single workflow, `.github/workflows/release.yaml`, handles **both** stable and
pre-release publishing. It fires whenever a `charts/*/Chart.yaml` `version:`
change lands on `main`, runs [`chart-releaser`](https://github.com/helm/chart-releaser-action)
(package each chart at its `Chart.yaml` version → GitHub Release + tag
`<chart>-<version>` → update the Helm repo index; `skip_existing` publishes only
new versions), and then **flags any chart whose version is a pre-release as a
GitHub pre-release / not "latest".**

The version in `Chart.yaml` is the single source of truth — including the
`-alpha`/`-beta` suffix. Engineers commit the version that generates the
release; there is no separate tag-driven path.

## Versioning

Charts use CalVer: `YYYY.M.serial`, e.g. `2026.6.9` — **no hyphen**.

A pre-release adds a SemVer-2 suffix to the *next* version: `2026.6.10-alpha.0`,
`2026.6.10-beta.1`. Helm sorts these below the corresponding stable version and
hides them from `helm pull` / `dependency update` unless `--devel` is passed or
the exact version is pinned. The release workflow also flags them as GitHub
pre-releases so they never become "latest".

## Bumping versions

Use the bump tooling rather than hand-editing `Chart.yaml`:

```bash
make gen_version_bump                   # all charts: 2026.6.9 -> 2026.6.10
make gen_version_bump PRERELEASE=alpha  # all charts: 2026.6.9 -> 2026.6.10-alpha.0
make gen_version_bump PRERELEASE=beta   # all charts: 2026.6.9 -> 2026.6.10-beta.0

# single chart:
invoke builder.version-bumper --file charts/controlplane/Chart.yaml --prerelease beta
```

The bump state machine (given the current `version`):

| Current | Command | Result |
|---------|---------|--------|
| `2026.6.9` | `PRERELEASE=alpha` | `2026.6.10-alpha.0` |
| `2026.6.10-alpha.0` | `PRERELEASE=alpha` | `2026.6.10-alpha.1` |
| `2026.6.10-alpha.3` | `PRERELEASE=beta` | `2026.6.10-beta.0` |
| `2026.6.10-beta.0` | `PRERELEASE=beta` | `2026.6.10-beta.1` |
| `2026.6.10-beta.2` | _(stable, no PRERELEASE)_ | `2026.6.10` |
| `2026.6.10-beta.2` | `PRERELEASE=alpha` | **error** (no going backward) |

A pre-release always targets the **next** base; a stable bump of an in-flight
pre-release **drops the suffix in place** (promotion), it does not advance the
serial.

## Cut a release (stable or pre-release)

1. Bump the version(s): `make gen_version_bump [PRERELEASE=alpha|beta]`.
2. Regenerate snapshots if templates/values changed: `make generate-expected`.
3. Open a PR and merge to `main`.
4. `release.yaml` publishes each new version. Plain CalVer → stable + latest;
   `-alpha`/`-beta` → GitHub pre-release, not latest.

Promotion is just a stable bump of the in-flight pre-release
(`2026.6.10-beta.2` → `2026.6.10`) merged to `main`.

## Consuming a pre-release

```bash
helm repo add union https://unionai.github.io/helm-charts
helm repo update
helm pull union/controlplane --devel                     # newest, including pre-releases
helm pull union/controlplane --version 2026.6.10-beta.0   # an exact pre-release
```

> Note: selfhosted/managed deployments pin this repo by **git ref** (via
> `revisions.yaml` in `unionai/cloud`), not by the Helm repo index — so for those
> consumers a pre-release version is mainly a stable, named point to pin against.
