data "aws_ami" "eks_node" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amazon-eks-node-${var.eks_version}*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

data "aws_ami" "eks_node_gpu" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amazon-eks-gpu-node-${var.eks_version}*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

# ################################################################################
# # Auto Generated application reference number
# ################################################################################

resource "random_string" "app_ref" {
  length  = 5
  special = false
  lower   = true
  number  = false
  upper   = false
}

locals {
  app_ref      = resource.random_string.app_ref.result
  cluster_name = join("-", compact(["${var.project_name}", "${var.environment}", "eks", local.app_ref]))
  partition    = data.aws_partition.current.partition
  vpc_name     = "${var.vpc_name}-${var.environment}"
}

################################################################################
# k8s Module
################################################################################

module "eks" {
  # https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest
  source  = "terraform-aws-modules/eks/aws"
  version = "18.26.6"

  cluster_name                    = local.cluster_name
  cluster_version                 = var.eks_version
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true

  # Required for Karpenter role below
  enable_irsa = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # We will rely only on the cluster security group created by the EKS service
  # See note below for `tags`
  create_cluster_security_group = true
  create_node_security_group    = true

  node_security_group_additional_rules = {
    # Control plane invoke Karpenter webhook
    ingress_karpenter_webhook_tcp = {
      description                   = "Control plane invoke Karpenter webhook"
      protocol                      = "tcp"
      from_port                     = 8443
      to_port                       = 8443
      type                          = "ingress"
      source_cluster_security_group = true
    },
    ingress_allow_access_from_control_plane = {
      type                          = "ingress"
      protocol                      = "tcp"
      from_port                     = 9443
      to_port                       = 9443
      source_cluster_security_group = true
      description                   = "Allow access from control plane to webhook port of AWS load balancer controller"
    },
    egress_to_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
  }

  # Only need one node to get Karpenter up and running.
  # This ensures core services such as VPC CNI, CoreDNS, etc. are up and running
  # so that Karpetner can be deployed and start managing compute capacity as required
  eks_managed_node_groups = {
    karpenter = {
      instance_types = ["t3.medium"]
      # We don't need the node security group since we are using the
      # cluster-created security group, which Karpenter will also use
      create_security_group                 = false
      attach_cluster_primary_security_group = true

      min_size     = 1
      max_size     = 1
      desired_size = 1

      iam_role_additional_policies = [
        # Required by Karpenter
        "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
      ]
    }
  }

  tags = merge(var.tags, {
    # Tag node group resources for Karpenter auto-discovery
    # NOTE - if creating multiple security groups with this module, only tag the
    # security group that Karpenter should utilize with the following tag
    "karpenter.sh/discovery" = local.cluster_name
  })

}

resource "aws_iam_instance_profile" "karpenter" {
  name = "KarpenterNodeInstanceProfile-${local.cluster_name}"
  role = module.eks.eks_managed_node_groups["karpenter"].iam_role_name

  depends_on = [
    module.eks
  ]
}

module "karpenter_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 4.21.1"

  role_name                          = "karpenter-controller-${local.cluster_name}"
  attach_karpenter_controller_policy = true

  karpenter_controller_cluster_id = module.eks.cluster_id
  karpenter_controller_ssm_parameter_arns = [
    "arn:${local.partition}:ssm:*:*:parameter/aws/service/*"
  ]
  karpenter_controller_node_iam_role_arns = [
    module.eks.eks_managed_node_groups["karpenter"].iam_role_arn
  ]

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["karpenter:karpenter"]
    }
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.cluster_name]
    }
  }
}

provider "kubectl" {
  apply_retry_count      = 5
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1alpha1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_id]
  }
}

resource "helm_release" "karpenter" {
  namespace        = "karpenter"
  create_namespace = true

  name       = "karpenter"
  repository = "https://charts.karpenter.sh"
  chart      = "karpenter"
  version    = "v0.13.2"

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.karpenter_irsa.iam_role_arn
  }

  set {
    name  = "clusterName"
    value = module.eks.cluster_id
  }

  set {
    name  = "clusterEndpoint"
    value = module.eks.cluster_endpoint
  }

  set {
    name  = "aws.defaultInstanceProfile"
    value = aws_iam_instance_profile.karpenter.name
  }
}

resource "kubectl_manifest" "karpenter_provisioner" {
  yaml_body = <<-YAML
  apiVersion: karpenter.sh/v1alpha5
  kind: Provisioner
  metadata:
    name: default
  spec:
    ttlSecondsAfterEmpty: 300
    labels:
      jina.ai/node-type: standard
    requirements:
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["spot", "on-demand"]
      - key: kubernetes.io/arch
        operator: In
        values: ["amd64"]
    limits:
      resources:
        cpu: 1000
    provider:
      launchTemplate: "karpenter-default-${local.cluster_name}"
      subnetSelector:
        karpenter.sh/discovery: ${local.cluster_name}
      tags:
        karpenter.sh/discovery: ${local.cluster_name}
    ttlSecondsAfterEmpty: 30
  YAML

  depends_on = [
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "karpenter_provisioner_gpu_shared" {
  yaml_body = <<-YAML
  apiVersion: karpenter.sh/v1alpha5
  kind: Provisioner
  metadata:
    name: gpu-shared
  spec:
    ttlSecondsAfterEmpty: 300
    labels:
      jina.ai/node-type: gpu-shared
      jina.ai/gpu-type: nvidia
      nvidia.com/device-plugin.config: shared_gpu
    requirements:
      - key: node.kubernetes.io/instance-type
        operator: In
        values: ["g4dn.xlarge", "g4dn.2xlarge", "g4dn.4xlarge", "g4dn.12xlarge"]
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["spot", "on-demand"]
      - key: kubernetes.io/arch
        operator: In
        values: ["amd64"]
    taints:
      - key: nvidia.com/gpu-shared
        effect: "NoSchedule"
    limits:
      resources:
        cpu: 1000
    provider:
      launchTemplate: "karpenter-gpu-shared-${local.cluster_name}"
      subnetSelector:
        karpenter.sh/discovery: ${local.cluster_name}
      tags:
        karpenter.sh/discovery: ${local.cluster_name}
    ttlSecondsAfterEmpty: 30
  YAML

  depends_on = [
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "karpenter_provisioner_gpu" {
  yaml_body = <<-YAML
  apiVersion: karpenter.sh/v1alpha5
  kind: Provisioner
  metadata:
    name: gpu
  spec:
    ttlSecondsAfterEmpty: 300
    labels:
      jina.ai/node-type: gpu
      jina.ai/gpu-type: nvidia
    requirements:
      - key: node.kubernetes.io/instance-type
        operator: In
        values: ["g4dn.xlarge", "g4dn.2xlarge", "g4dn.4xlarge", "g4dn.12xlarge"]
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["spot", "on-demand"]
      - key: kubernetes.io/arch
        operator: In
        values: ["amd64"]
    taints:
      - key: nvidia.com/gpu
        effect: "NoSchedule"
    limits:
      resources:
        cpu: 1000
    provider:
      launchTemplate: "karpenter-gpu-${local.cluster_name}"
      subnetSelector:
        karpenter.sh/discovery: ${local.cluster_name}
      tags:
        karpenter.sh/discovery: ${local.cluster_name}
    ttlSecondsAfterEmpty: 30
  YAML

  depends_on = [
    helm_release.karpenter
  ]
}

resource "aws_launch_template" "karpenter" {
  name = "karpenter-default-${local.cluster_name}"

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = 80
    }
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.karpenter.name
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      "karpenter.sh/discovery" = local.cluster_name
      "jina.ai/node-type"      = "standard"
    }
  }

  image_id = data.aws_ami.eks_node.image_id

  instance_initiated_shutdown_behavior = "terminate"

  update_default_version = true

  # key_name = "${local.cluster_name}-sshkey"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 2
  }

  vpc_security_group_ids = [module.eks.node_security_group_id]

  user_data = base64encode(templatefile("${path.module}/customized_bootstraps.sh", { cluster_name = "${local.cluster_name}" }))

  tags = {
    "karpenter.sh/discovery" = local.cluster_name
    "node-type"              = "standard"
  }
}

resource "aws_launch_template" "gpu" {
  name = "karpenter-gpu-${local.cluster_name}"

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = 120
    }
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.karpenter.name
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      "karpenter.sh/discovery" = local.cluster_name
      "jina.ai/node-type"      = "gpu"
    }
  }

  image_id = data.aws_ami.eks_node_gpu.image_id

  instance_initiated_shutdown_behavior = "terminate"

  update_default_version = true

  # key_name = "${local.cluster_name}-sshkey"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 2
  }

  vpc_security_group_ids = [module.eks.node_security_group_id]

  user_data = base64encode(templatefile("${path.module}/customized_bootstraps.sh", { cluster_name = "${local.cluster_name}" }))

  tags = {
    "karpenter.sh/discovery" = local.cluster_name
    "node-type"              = "gpu"
  }
}

resource "aws_launch_template" "gpu_shared" {
  name = "karpenter-gpu-shared-${local.cluster_name}"

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = 360
    }
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.karpenter.name
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      "karpenter.sh/discovery" = local.cluster_name
      "jina.ai/node-type"      = "gpu-shared"
    }
  }

  image_id = data.aws_ami.eks_node_gpu.image_id

  instance_initiated_shutdown_behavior = "terminate"

  update_default_version = true

  # key_name = "${local.cluster_name}-sshkey"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 2
  }

  vpc_security_group_ids = [module.eks.node_security_group_id]

  user_data = base64encode(templatefile("${path.module}/customized_bootstraps.sh", { cluster_name = "${local.cluster_name}" }))

  tags = {
    "karpenter.sh/discovery" = local.cluster_name
    "node-type"              = "gpu-shared"
  }
}

################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = local.vpc_name
  cidr = var.cidr

  azs             = var.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  enable_vpn_gateway = false

  manage_default_network_acl = true
  default_network_acl_tags   = { Name = "${local.vpc_name}-default" }

  manage_default_route_table = true
  default_route_table_tags   = { Name = "${local.vpc_name}-default" }

  manage_default_security_group = true
  default_security_group_tags   = { Name = "${local.vpc_name}-default" }

  enable_dns_support = true

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = 1
    # Tags subnets for Karpenter auto-discovery
    "karpenter.sh/discovery" = local.cluster_name
  }

  tags = var.tags
}

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 3.0"

  vpc_id             = module.vpc.vpc_id
  security_group_ids = [module.vpc_endpoint_security_group.security_group_id]

  endpoints = {
    ssm = {
      service             = "ssm"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
    },
    ssmmessages = {
      service             = "ssmmessages"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
    },
    lambda = {
      service             = "lambda"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
    },
    ecs = {
      service             = "ecs"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
    },
    ecs_telemetry = {
      create              = false
      service             = "ecs-telemetry"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
    },
    ec2 = {
      service             = "ec2"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
    },
    ec2messages = {
      service             = "ec2messages"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
    },
    ecr_api = {
      service             = "ecr.api"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
    },
    ecr_dkr = {
      service             = "ecr.dkr"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
    },
    monitoring = {
      service             = "monitoring"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
    },
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.vpc.private_route_table_ids
    }
  }

  tags = var.tags
}

module "vpc_endpoint_security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = join("-", compact(["${local.vpc_name}-k8s-endpoints"]))
  description = "Security group for VPC endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = [var.cidr]
  ingress_rules       = ["https-443-tcp"]

  egress_cidr_blocks = ["0.0.0.0/0"]
  egress_rules       = ["https-443-tcp"]

  tags = var.tags
}
