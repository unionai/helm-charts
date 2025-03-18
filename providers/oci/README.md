# Installing BYOK on OCI

This guide will walk you through the process of installing the BYOK (Bring Your Own Kubernetes) operator on Oracle Cloud Infrastructure (OCI). We assume that you have properly configured access to OCI, belong to a group that allows enough privelages to create infrastructure and services, and have installed the OCI command line tool.

## Install the minimal OCI infrastructure components.

### Requirements

* terraform

### Instructions

We'll use terraform to set up the infrastructure for a minimum installation.

Create a file to define some installation specific variables:

```ini
user_ocid = "<replace_me>"
fingerprint = "<replace_me>"
tenancy_ocid = "<replace_me>"
region = "<replace_me>"
storage_user_email = "my-storage+user@example.com"
```

This defines the minimum set of variables required to run the installation.  Others are also available: [see variables.tf](variables.tf).  Once you've defined your variables, run the following:

```shell
terraform plan --var-file variables.tfvars --var private_key_path=<path_to_private_key>/private.pem
```

This will create the supporting identity components, object storage, and a container engine cluster (OKE) with a single node pool.  Once complete you will be presented with information about some different components you will need to finish the setup.  Save this information or run apply again.

## Install the union dataplane services

### Requirements

* kubectl

### Instructions

#### Set up kubectl access to your cluster

Using the compartment id output from the last step, get the cluster id:

```shell
oci ce cluster list --compartment-id <compartment_id> --name union-dp | jq -r '[.data[] | select(."lifecycle-state" | contains("ACTIVE"))][0] | .id'
```

Then use the compartment id from the last step to update your kubernetes configuration file:

```shell
oci ce cluster create-kubeconfig --cluster-id <compartment_id> --region <region> --token-version 2.0.0
```

You can optionally specify `--file` to change the location from the default `~/.kube/config`.
