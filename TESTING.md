# Testing

CI for this repo runs in two tiers, gated by whether a pull request is a
**release**.

## Every PR — static analysis

Runs on every pull request to `main`, for anyone (including forks). No cluster
access, fast:

| Check | What it does |
|---|---|
| `lint` | `helm lint` the charts |
| `validate` (`make helm-test`) | render the charts and diff against the committed snapshots in `tests/generated/` |
| `kubeconform` | schema-validate the rendered manifests |
| `vendored-crds` | verify the vendored CRDs are in sync |
| `release-notes` | `RELEASE.md` is updated |

If `validate` fails after a template or values change, regenerate the snapshots
and commit them alongside your change:

```bash
make generate-expected   # re-render the tests/generated/ snapshots
make test                # confirm they match (validate == make helm-test)
git add tests/generated && git commit
```

## Integration test suite

`.github/workflows/integration-checks.yaml` runs in two tiers:

- The **k3d leg runs on every PR** to `main` — self-contained (ephemeral k3d
  cluster installed with `charts/dataplane/values.k3d.yaml`), with a binary
  health gate and the pytest functional suite (`tests/functional/`).
- The **five cloud legs run on release PRs** (or with the
  `run-integration-tests` label, or a `workflow_dispatch` with `force=true`):
  the candidate charts are installed onto standing canary clusters and
  exercised end-to-end — selfmanaged-dp `aws` / `gcp` / `azure` and selfhosted
  `aws` / `gcp`.

**A PR is classified as a release when either:**

- a chart's `version:` is bumped in `charts/*/Chart.yaml`, **or**
- the PR title starts with `Release ` (e.g. `Release 2026.7.2`).

Release PRs are **required** to pass the integration suite before merge.

### Union organization members only

The integration legs authenticate to the test infrastructure via keyless GitHub
OIDC into the `helm-charts-ci` GitHub Environment (per-cloud deployer identities,
provisioned by terraform in `unionai/cloud`). **Fork PRs get no OIDC token**, so
the integration suite can only run from branches pushed to `unionai/helm-charts`
— i.e. by Union organization members. Fork contributors get the static-analysis
tier only; a maintainer re-runs the release/integration checks from a same-repo
branch.

## Manually triggering the integration suite (any PR)

Any Union organization member (write access) can run the full integration matrix
on demand against any PR in `unionai/helm-charts` — their own, or someone else's.
This is the same matrix a release PR runs; use it to validate infra/CI changes
that don't bump a chart `version`, or to green-light a PR before merge.

**Add the `run-integration-tests` label to the PR** (easiest). The suite runs on
that PR's head immediately, and re-runs on each subsequent push while the label
is set. Remove the label to stop re-running.

**Or dispatch the workflow** against a branch — set `--ref` to the PR's head
branch:

```bash
gh workflow run integration-checks.yaml --ref <pr-branch> -f force=true
```

(Or from the UI: Actions → **Integration Checks** → **Run workflow** → pick the
branch → set **force** to `true`.)

> **Fork PRs** can't use either path — their branch doesn't live in
> `unionai/helm-charts`, and the integration legs can't obtain an OIDC token from
> a fork regardless. A maintainer must first bring the change onto a same-repo
> branch (e.g. `gh pr checkout <pr#>` then push to `origin`) and label/dispatch that.
