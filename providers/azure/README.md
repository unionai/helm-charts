# Installing BYOK on Azure

This guide will walk you through the process of installing the BYOK (Bring Your Own Kubernetes) operator on Microsoft Azure. We assume that you have properly configured access to Azure and sufficient permissions.

## Install the minimal Azure infrastructure components.

### Requirements

* terraform

### Instructions

We'll use terraform to set up the infrastructure for a minimum installation.

Create a file to define some installation specific variables:

```ini
union_org = "<replace_me>" # Union organization
name_prefix = "<replace_me>" # Prefix preceding created resources
location = "<replace_me>" # Azure location
```

This defines the minimum set of variables required to run the installation.  Others are also available: [see variables.tf](variables.tf).  Once you've defined your variables, run the following:

```shell
ARM_SUBSCRIPTION_ID=<AZURE_SUBSCRIPTION_ID>
terraform plan --var-file variables.tfvars
```

This will create the supporting identity components, object storage, and a Azure Kubernetes Service AKS instance.  Once complete you will be presented with information about some different components you will need to finish the setup.  Save this information or run apply again.

## Install the union dataplane services

### Requirements

* kubectl
* azure-cli

### Instructions

#### Set up kubectl access to your cluster

Update your :

```shell
az aks get-credentials --resource-group <resource_group_name> --name <kubernetes_name>
```

#### Install the dataplane helm chart.

Use [azure-template-values.yaml](./azure-template-values.yaml) as an Azure specific values.yaml template. Refer to [README.md](../../README.md) for further installation instructions.
