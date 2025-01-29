variable "tenancy_ocid" {
  type = string
}

variable "user_ocid" {
  type = string
}

variable "fingerprint" {
  type = string
}

variable "private_key_path" {
  type = string
}

variable "region" {
  type    = string
  default = "us-sanjose-1"
}

variable "vcn_cidr" {
  type    = string
  default = "10.96.0.0/16"
}

variable "nodepool_cidr" {
  type    = string
  default = "10.96.128.0/17"
}

variable "api_endpoint_cidr" {
  type    = string
  default = "10.96.0.0/24"
}

variable "lb_cidr" {
  type    = string
  default = "10.96.1.0/24"
}

variable "pods_cidr" {
  type    = string
  default = "10.97.0.0/16"
}

variable "services_cidr" {
  type    = string
  default = "10.98.0.0/16"
}

# https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengrunninggpunodes.htm#contengrunninggpunodes_topic-supportedgpushapes
variable "node_shape" {
  type    = string
  # default = "VM.Standard3.Flex"
  default = "VM.GPU.A10.1"
}

variable "node_cpus" {
  type    = number
  default = 4
}

variable "node_memory_gb" {
  type    = number
  default = 16
}

variable "node_boot_volume_size_gb" {
  type    = number
  default = 50
}

variable "image_id" {
  type = string
  # Oracle-Linux-8.10-2024.09.30-0-OKE-1.31.1-748
  # default = "ocid1.image.oc1.us-sanjose-1.aaaaaaaac4onum4ux63szstw3ykptcyayamk6473zex6lba7kv63astrd6vq"
  # Oracle-Linux-8.10-Gen2-GPU-2024.09.30-0-OKE-1.31.1-747
  default = "ocid1.image.oc1.us-sanjose-1.aaaaaaaahq4jtk5oteo5zwumf235rtlx6fcsgs4cftrvrwcayq5vmcr4uhxa"
}

variable "node_count" {
  type    = number
  default = 1
}

variable "storage_user_email" {
  type = string
}
