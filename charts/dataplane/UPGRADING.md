# Upgrading the dataplane chart

Each release has an upgrade skill under `upgrades/<version>/` covering exactly one version
hop. Each is both a skill you can hand to a coding agent and a runbook you can follow by
hand.

## How to use these

**Upgrading one version.** Read the skill for your target version. It lists what you must
change, what changes without you, how to verify, and how to roll back.

**Jumping several versions.** Read every skill between your current version and your
target, **oldest first**. They compose: each covers one hop, and applying them in order
gets you there. A key deprecated in one release and removed in a later one shows up in
both, and the later entry supersedes.

**Working with an agent.** Point it at this directory along with your values file:

> Read `charts/dataplane/UPGRADING.md` and every skill in `charts/dataplane/upgrades/`
> between `<CURRENT>` and `<TARGET>`, oldest first. My values file is at `<PATH>`. Tell me
> what I need to change and why, then give me the upgrade commands.

Each directory also has a `changes.yaml` — the same content in machine-readable form, so
an agent can merge a version range without reading every prose document.

## Before any upgrade

```bash
NS=<YOUR_NAMESPACE>
REL=<YOUR_RELEASE_NAME>

helm get values "$REL" -n "$NS" -o yaml > values-backup-$(date +%Y%m%d-%H%M).yaml
helm list -n "$NS"
kubectl get pods -n "$NS" --field-selector=status.phase!=Running
```

Start from a healthy baseline. If pods are already failing, resolve that first — otherwise
you will not be able to tell whether the upgrade caused it.

## The one thing to know about Helm and this chart

Helm does not validate your values against a schema. **A key the chart no longer reads is
accepted and silently ignored.** No warning, no error, and every pod comes up healthy.

This is why the guides exist and why the "required values changes" section of each one
matters more than it looks. A renamed key is not a cosmetic change here — it means the
configuration you wrote stopped taking effect, and nothing will tell you.

## Releases

| Version | Impact | Headline |
|---|---|---|
| [2026.8.0](upgrades/2026.8.0/SKILL.md) | **Breaking** | Legacy executor removed; `executor.*` keys retired; per-cloud overlay defaults moved into the base chart; image references fully qualified |

## If you are unsure

These guides are written to be followed without Union involvement, and most upgrades are
routine. If your deployment diverges from the chart defaults in ways the guide does not
address, or an upgrade does not verify cleanly, contact Union support with your chart
version, your verification command output, and the relevant pod logs — or open an issue on
`unionai/helm-charts`.

## Related

- `RELEASE.md` — full release notes for every version, including changes that need no
  action from you
- `README.md` — chart values reference
