# EKS Terraform Template

*Templates of some useful terraform deployments*


## GPU with Kapenter

*Can refer to [Using Karpenter to manage GPU nodes with time-slicing](https://alphatango086.medium.com/using-karpenter-to-manage-gpu-nodes-with-time-slicing-129098a72cb6)*

### deployment
```{hint}
Before deployment, You need to change terraform.tfvars. I provided a template in repo.
```

After you setup the terraform.tfvar and AWS credentials. Run below command

```bash
$ terraform init
$ terraform apply
```

