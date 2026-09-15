locals {
  environment  = "dev"
  cluster_name = "cloudgeeks-eks-dev"

  # Must be a version in EKS standard support. The sandbox blocks
  # extended-support versions because they bill at a premium.
  kubernetes_version = "1.36"
}
