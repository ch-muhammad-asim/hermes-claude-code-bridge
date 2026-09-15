include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//oidc/github"
}

inputs = {

  github_repos = [
    "quickbooks2018/github-oidc-aws",
  ]

}