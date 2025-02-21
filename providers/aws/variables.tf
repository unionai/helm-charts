variable "aws_cli_profile" {
type = string
}

variable "aws_region"{
    type = string
}

variable "node_groups" {
    type = map(object({
        instance_type = string
        dedicated_node_role = string
        min_size = number
        max_size = number
        root_disk_size_gb = number
        spot = bool
        gpu_accelerator = string
        gpu_count = number
    }))
    default = {
        worker-on-demand = {
            instance_type = "m7i.xlarge"
            dedicated_node_role = "worker"
            min_size            = 2
            max_size            = 5
            root_disk_size_gb   = 500
            spot = false
            gpu_accelerator = ""
            gpu_count = 0
        }
    }
}

variable "admin_role_arns" {
  type    = list(string)
  default = []
}

variable "admin_user_arns" {
  type    = list(string)
  default = []
}

variable "node_role_arns" {
  type    = list(string)
  default = []
}

variable "admin_role_regexes" {
  type    = list(string)
  default = []
}

