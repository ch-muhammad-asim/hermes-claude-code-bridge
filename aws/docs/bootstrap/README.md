# 🪣 Remote state

State storage cannot live in the state it stores, so the bucket is created outside
Terraform — but **not** by hand. Terragrunt bootstraps it:

```bash
terragrunt backend bootstrap --working-dir vpc
```

Or let it happen inline on the first apply:

```bash
export TG_BACKEND_BOOTSTRAP=true
```

Terragrunt creates the bucket with versioning, SSE-KMS, a public-access block and a
TLS-only policy. Locking is S3-native (`use_lockfile`), so there is no DynamoDB table
to create or pay for.

## 🔢 The bucket name is derived, not configured

`account.hcl` discovers the account id at runtime and builds the bucket name from it:

```hcl
aws_account_id = run_cmd("--terragrunt-quiet", "aws", "sts", "get-caller-identity", "--query", "Account", "--output", "text")
state_bucket   = "cloudgeeks-eks-blueprints-tfstate-${local.aws_account_id}"
```

An account id makes the name globally unique, and deriving it means a reissued
sandbox needs **no edit at all**. Pin it for a long-lived account:

```bash
export TG_AWS_ACCOUNT_ID=123456789012
```

Pinning also re-arms the wrong-account guard in `root.hcl`, which is only a real
safety net when it has something independent to compare against.

## 🔑 Customer-managed KMS key (optional)

`terragrunt backend bootstrap` creates and hardens the **bucket**, but it does not
create KMS keys. So the state config uses the bucket's SSE-KMS default unless you
point it at a key you have already created:

```bash
export TG_STATE_KMS_KEY=alias/terraform-state
```

Naming a CMK that does not exist yet fails every state write with
`NotFoundException` on the alias — which is why this is opt-in rather than the
default.

## ♻️ Switching to a new sandbox — clear the cache first

**This is the one manual step a reissued sandbox needs.** `.terragrunt-cache/`
holds a generated `backend.tf` with the *previous* account's bucket baked in, and
dependency resolution reads that cached directory. Leave it in place and you get a
confusing pair of errors — a `NoSuchBucket` for an account you are no longer in,
followed by `There is no variable named "dependency"` as the cascade:

```bash
find . -type d -name '.terragrunt-cache' -exec rm -rf {} + 2>/dev/null
```

Then bootstrap and apply normally. Nothing else needs changing: the account id, the
bucket name and the operator CIDR are all discovered.

## 🧹 Teardown

The bucket is not managed by Terraform, so `destroy` leaves it. Remove it explicitly
when you are finished with an account — note it is versioned, so every version must
go:

```bash
aws s3 rb "s3://cloudgeeks-eks-blueprints-tfstate-$(aws sts get-caller-identity --query Account --output text)" --force
```
