# Disclosure policy

Everything this skill writes lands in a **public repository** and is handed to customers.
The generating agent, by contrast, typically has access to internal context — the Union
platform source, ticket trackers, internal design docs, support conversations, and other
customers' configuration. That asymmetry is the risk this policy exists to manage.

The rule is simple to state and easy to violate by accident:

> **Use internal context to understand. Never use it to explain.**

You may read anything you have access to in order to work out what a change does. What
you write must be justified by, and traceable to, the public chart alone.

---

## Never appears in output

**Customer identity, in any form**
- Organization names, org slugs, tenant names, account names
- Cluster names, node pool names, queue or cluster-pool names
- Hostnames and any domain under a Union-operated zone
- Anything that would let a reader work out which customer hit a problem — including a
  configuration described specifically enough to be a fingerprint

**Credentials and cloud account identifiers**
- Cloud account numbers, subscription IDs, tenant IDs, project IDs
- Client IDs, workload-identity IDs, principal IDs, role ARNs, service account emails
- Registry hostnames belonging to a specific account (private ECR, ACR, GAR paths)
- Anything that looks like a secret, key, or token, even a redacted-looking one

**Internal engineering context**
- Paths, filenames, or line references outside this repository
- Source excerpts from any non-public repository
- Internal service, module, or package names not already named by the public chart
- Names of internal environments, staging tenants, or internal test deployments
- Internal architectural reasoning that the chart does not itself expose

**Internal process artifacts**
- Ticket identifiers and tracker URLs
- Links to internal wikis, docs, recordings, or chat
- Employee or customer individuals' names
- Roadmap, timelines, or "we plan to" statements about unshipped work
- Characterizations of a change as a mistake, regression, or incident

**Anything not yet public**
- Flags, keys, or features present in the source but not in the released chart
- Behavior of an unreleased version

---

## Safe to cite

- Paths and content inside `unionai/helm-charts` — it is public
- Chart values keys, template names, and rendered object names
- Public GitHub release pages and tags for this repository
- Published Union documentation
- Upstream project documentation for subchart dependencies
- Standard `kubectl` / `helm` invocations
- Generic, non-attributable configuration shapes — a values snippet written from the
  chart's own defaults rather than copied from a real deployment

---

## Rewriting internal findings for public output

The recurring case is a change whose meaning you learned from internal source. Restate it
as observable consequence, prerequisite, and verification — never as mechanism.

| Do not write | Write instead |
|---|---|
| "`<internal-service>/service/foo.go:NNN` re-claims the wildcard on each reconcile" | "Only one cluster per tenant can serve public app traffic. Enabling it on a second cluster causes intermittent failures on app URLs." |
| "Broke for `<org>` because their project routed to a different pool" | "If the app's image was built into a registry the serving cluster cannot reach, the deployment fails to pull. Confirm the image is reachable from the target cluster." |
| "Fixes the bug from PROJ-NNNN" | "Fixes an issue where an unset storage container name produced a log-forwarder configuration that could not start." |
| "The authorizer previously no-opped, see the authz middleware" | "Authorization moves from permissive to enforcing. Requests are now checked against the control plane." |

Note what survives the rewrite: what the customer will observe, what they must do, how
they check. Note what does not: who, where in the source, and which ticket.

---

## Two-stage gate

**Stage 1 — mechanical.** `assets/scan-disclosure.sh` greps for the patterns above.
Run it on every generated file. It catches identifiers, IDs, ticket keys, internal
hostnames, and known org slugs.

Two lists are deliberately **not** hardcoded in the script, because the script itself may
be committed to a public repository and those lists are exactly what this policy protects:

| List | Supply via | Or file |
|---|---|---|
| Self-managed customer org slugs | `UNION_ORG_SLUGS` | `.disclosure-orgs` |
| Internal repository / service names | `UNION_INTERNAL_PATHS` | `.disclosure-paths` |

Both take a `|`-separated alternation (the files take one entry per line). Neither file
should ever be committed — `assets/.gitignore` covers them. The script warns loudly when a
list is missing, because a scan without one is materially weaker.

**Stage 2 — judgment.** The scan cannot catch:
- A scenario described so specifically it identifies one deployment
- A rationale that only makes sense with internal knowledge, and so implies it
- An implied roadmap ("this prepares for...")
- A tone that reveals an incident rather than describing a change

After the scan passes, reread both output files and ask, for each paragraph: *could a
person outside Union have written this from the public chart alone?* If not, cut it or
rewrite it as consequence.

**Never weaken the scan to make output pass.** If the scan flags something, the output is
wrong, not the scan.

---

## Sourcing the configuration examples

Every values snippet in generated output must be written from the chart's own
`values.yaml` and per-cloud overlays.

**Do not render, diff, or copy from a real customer's values file**, including ones
present in a local working directory, a scratch folder, or a support attachment. Use the
synthetic profiles in `assets/profiles/`, which are built to exercise the same
configuration axes with no identifying content.

This holds even when a real file would be more convincing. A snippet that carries a real
account ID is a disclosure incident regardless of how good the guidance around it is.
