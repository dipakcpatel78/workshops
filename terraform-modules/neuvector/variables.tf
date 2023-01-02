# Variables for neuvector terraform module

# Required
variable "kubernetes_config_path" {
  type        = string
  description = "config path connecting to the kubernetes cluster where neuvector is target to deploy to"
}

# required
variable "neuvector_sslcert_path" {
  type        = string
  description = "output path for neuvector SSL cert (private key and cert)"
}

variable "neuvector_helm_chart_version" {
  type        = string
  description = "Version of neuvector to install (format: 0.0.0)"
  default     = "2.2.2"
}

variable "neuvector_version" {
  type        = string
  description = "Version of neuvector to install (format: 0.0.0)"
  default     = "5.1.0"
}

variable "ingress_host" {
  type        = string
  description = "hostname for ingress controller"
}

variable "neuvector_depends_on" {
  type    = any
  default = []
}

