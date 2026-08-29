###############################################################################
# AWS Load Balancer Controller - IAM role, policy and Pod Identity association
#
# The Helm release itself is installed separately:
#   kubernetes/aws-load-balancer-controller/README.md
###############################################################################

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//alb-controller-iam"
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs = {
    cluster_name = "mock-cluster"
  }

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
}

inputs = {
  cluster_name = dependency.eks.outputs.cluster_name

  # Must match serviceAccount.name in the Helm values, or Pod Identity will not
  # bind and the controller will fail with AccessDenied on ELB calls.
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
}
