output "project_name" {
  description = "Project Name of the AWS Resources"
  value       = var.project_name
}

output "environment" {
  description = "Project Name of the AWS Resources"
  value       = var.environment
}

output "app_ref" {
  description = "Project Name of the AWS Resources"
  value       = local.app_ref
}

output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

# output "node_ssh_key_id" {
#   description = "ssh key id of the nodes"
#   value       = resource.aws_key_pair.k8s_ec2_key_pair.id
# }
