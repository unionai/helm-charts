# Synthetic render profiles

These are **not** anyone's deployment. Every value is a placeholder chosen to be obviously
fictional. They exist to exercise the configuration axes that vary across self-managed
clusters so a render diff surfaces changes on each of them.

**Never replace one of these with a real customer values file**, including one sitting in
a local working directory or attached to a support conversation. See
`../../references/disclosure-policy.md`.

| Profile | Cloud | Apps | Zero Trust | Privilege | Notes |
|---|---|---|---|---|---|
| `minimal.yaml` | none | off | off | standard | Subcharts off — isolates base-chart behavior |
| `aws-selfmanaged.yaml` | AWS | off | off | standard | IRSA identity, S3 storage |
| `gcp-selfmanaged.yaml` | GCP | **on** | off | standard | Workload Identity, GCS storage |
| `azure-selfmanaged.yaml` | Azure | **on** | **on** | low | Workload Identity, blob storage |

When a release introduces a genuinely new configuration axis, add a profile rather than
overloading an existing one. Keep each file short — its readability is what makes it
obviously non-identifying.

Placeholder conventions, so a disclosure scan never has to guess:

- Org: `example-org`
- Clusters: `example-<cloud>-1`
- Host: `controlplane.example.invalid` (`.invalid` is reserved by RFC 2606 and can never resolve)
- Cloud identifiers: `000000000000`, `00000000-0000-0000-0000-000000000000`
- Buckets/containers: `example-metadata-bucket`

## These files intentionally fail the disclosure scan

`scan-disclosure.sh` flags all-zero cloud identifiers, because it cannot distinguish an
obviously-fake placeholder from a real one. That is the correct trade-off: the rule stays
strict for the files that actually get published.

**The scan targets generated skills under `charts/dataplane/upgrades/`, not this
directory.** Do not relax the scan to make these profiles pass, and do not replace the
placeholders with values that merely look less like identifiers — an all-zero identifier is
unmistakably synthetic to a human reader, which is what matters here.
