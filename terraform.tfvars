region             = "ap-southeast-1"
environment        = "dev"
project_name       = "wolf"

vpc_name           = "jina-eks-vpc"
eks_version        = "1.21"

cidr               = "10.200.0.0/16"
azs                = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
public_subnets     = ["10.200.101.0/24", "10.200.102.0/24", "10.200.103.0/24"]
private_subnets    = ["10.200.1.0/24", "10.200.2.0/24", "10.200.3.0/24"]

tags = {
    Terraform   = "true"
    Environment = "dev"
}