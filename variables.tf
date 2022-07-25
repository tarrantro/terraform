variable "region" {
  description = "Region of the AWS resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project Name of the AWS Resources"
  type        = string
  default     = ""
}

variable "eks_version" {
  description = "EKS version"
  type        = string
  default     = ""
}

# variable "app_ref" {
#   description = "Application Reference ID of the AWS Resources"
#   type        = string
#   default     = ""
# }

variable "environment" {
  description = "Environment of the AWS resources"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags for AWS Resource"
  type        = map(string)
  default     = {}
}

variable "vpc_name" {
  description = "Name to be used on all the resources as identifier"
  type        = string
  default     = ""
}

variable "cidr" {
  description = "The CIDR block for the VPC. Default value is a valid CIDR, but not acceptable by AWS and should be overriden"
  type        = string
  default     = "0.0.0.0/0"
}

variable "azs" {
  description = "A list of availability zones in the region"
  type        = list(string)
  default     = []
}

variable "public_subnets" {
  description = "A list of public subnets inside the VPC"
  type        = list(string)
  default     = []
}

variable "private_subnets" {
  description = "A list of private subnets inside the VPC"
  type        = list(string)
  default     = []
}
