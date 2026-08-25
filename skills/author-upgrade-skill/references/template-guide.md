# Filling the template

The failure mode for a generated upgrade guide is not being wrong. It is being padded,
hedged, and therefore skipped. These rules exist to prevent that.

## Length

Target 200 lines. Hard cap 300. If you are over, cut in this order:

1. Narrative and background — the reader wants to act, not be educated
2. Restating what a table already says
3. Generic Helm advice they already know
4. Optional-feature detail — link, do not explain

Never cut a finding to fit. If a release genuinely has 300 lines of findings, ship 300
lines of findings with no prose at all.

## Voice

Write to a competent platform engineer who has never seen this chart's internals and has
no Union context beyond their own deployment.

- Imperative for actions: "Set `storage.enableMultiContainer: false`"
- Indicative for consequences: "Log forwarding stops until this is set"
- No "simply", "just", "easily", "should be straightforward"
- No apologising for the change and no selling it
- Second person for what they do; never first-person plural for what Union did

## Commands must be runnable

Every command must be copy-pasteable, with placeholders in an obvious `<ANGLE_BRACKET>`
form and a note above the block saying what to substitute. Never write "run helm upgrade
with your values file" — write the command with `<YOUR_VALUES>.yaml` in it.

## Verification must be falsifiable

Every check names the exact expected output.

| Bad | Good |
|---|---|
| "Check the pods are healthy" | ``kubectl get pods -n <NAMESPACE> --field-selector=status.phase!=Running`` — expect no rows |
| "Verify the version" | ``helm list -n <NAMESPACE> -o json \| jq -r '.[0].chart'`` — expect `dataplane-<VERSION>` |
| "Make sure logs work" | "Run any workflow, then confirm objects appear under your log prefix in the configured storage container within ~2 minutes" |

If you cannot write a falsifiable check for a change, say so: "No direct check available —
contact Union support if X does not behave as expected after upgrading." That is honest
and useful. A vague check is neither.

## Tables over prose

Silent default flips, removed keys, and image changes are always tables. A reader scanning
for "does this affect me" needs to match on key names, and prose makes that impossible.

Required columns for the silent-flip table: key, old default, new default, **to keep
current behavior**. That last column is the one that gets used.

## Separating required from optional

The single most important structural rule. A reader must be able to determine the minimum
they must do without reading the whole document.

Everything above the verification section is required. Everything below is optional.
No exceptions, no "optional but recommended" hedging in the required section.

## Uncertainty

State it. "This changes authorization behavior; if your control plane was configured
before <version>, confirm with Union support before upgrading" is a good line. Silent
guessing is not, and neither is hedging every statement to avoid being wrong.

Mark anything you could not establish with a `> **Unverified**` blockquote so the human
reviewer can resolve it before merge. Never delete an uncertain finding to make the
document look cleaner.

## Cross-version jumps

Every skill covers exactly one hop. Do not summarise earlier releases, and do not
speculate about later ones. The index at `charts/dataplane/UPGRADING.md` handles
composition, and `changes.yaml` is what an agent merges across a range.

The one exception: if a key **this** release removes was deprecated in an earlier release,
say which release deprecated it. That is what lets a range-merging agent collapse the two
into a single instruction.
