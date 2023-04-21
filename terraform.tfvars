region             = "us-west-2"
environment        = "dev"
project_name       = "gpu-share"

vpc_name           = "spark-k8s-monitor"
eks_version        = "1.25"

cidr               = "10.1.0.0/16"
azs                = ["us-west-2a", "us-west-2b", "us-west-2c"]
public_subnets     = ["10.1.192.0/20", "10.1.208.0/20", "10.1.224.0/20"]
private_subnets    = ["10.1.0.0/18", "10.1.64.0/18", "10.1.128.0/18"]

tags = {
    Terraform   = "true"
    Environment = "dev"
}
