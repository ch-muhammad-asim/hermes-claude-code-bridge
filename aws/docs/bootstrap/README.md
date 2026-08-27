# 🪣 Bootstrapping remote state

State storage cannot live in the state it stores, so the bucket and key are
created once, outside Terraform. Everything after this is Terragrunt.

The bucket uses SSE-KMS with a customer-managed key, versioning, a public
access block, TLS-only and encryption-only bucket policies, and a lifecycle
rule that expires non-current versions. Locking is S3-native (`use_lockfile`),
so there is no DynamoDB table to create or pay for.

Set your account id and pick a bucket name:

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

```bash
export STATE_BUCKET="cloudgeeks-eks-blueprints-tfstate-${ACCOUNT_ID}"
```

Create the KMS key, enable rotation and alias it:

```bash
export KMS_KEY_ID=$(aws kms create-key --description "Terraform/Terragrunt remote state encryption" --query 'KeyMetadata.KeyId' --output text)
```

```bash
aws kms enable-key-rotation --key-id "$KMS_KEY_ID"
```

```bash
aws kms create-alias --alias-name alias/terraform-state --target-key-id "$KMS_KEY_ID"
```

Create and harden the bucket:

```bash
aws s3api create-bucket --bucket "$STATE_BUCKET" --region us-east-1
```

```bash
aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" --versioning-configuration Status=Enabled
```

```bash
aws s3api put-public-access-block --bucket "$STATE_BUCKET" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

```bash
aws s3api put-bucket-encryption --bucket "$STATE_BUCKET" --server-side-encryption-configuration "{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\",\"KMSMasterKeyID\":\"$KMS_KEY_ID\"},\"BucketKeyEnabled\":true}]}"
```

```bash
aws s3api put-bucket-ownership-controls --bucket "$STATE_BUCKET" --ownership-controls '{"Rules":[{"ObjectOwnership":"BucketOwnerEnforced"}]}'
```

```bash
aws s3api put-bucket-lifecycle-configuration --bucket "$STATE_BUCKET" --lifecycle-configuration '{"Rules":[{"ID":"expire-noncurrent-state","Status":"Enabled","Filter":{},"NoncurrentVersionExpiration":{"NoncurrentDays":90,"NewerNoncurrentVersions":10},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":7}}]}'
```

Deny plaintext transport and unencrypted uploads:

```bash
aws s3api put-bucket-policy --bucket "$STATE_BUCKET" --policy "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"DenyInsecureTransport\",\"Effect\":\"Deny\",\"Principal\":\"*\",\"Action\":\"s3:*\",\"Resource\":[\"arn:aws:s3:::$STATE_BUCKET\",\"arn:aws:s3:::$STATE_BUCKET/*\"],\"Condition\":{\"Bool\":{\"aws:SecureTransport\":\"false\"}}},{\"Sid\":\"DenyUnencryptedObjectUploads\",\"Effect\":\"Deny\",\"Principal\":\"*\",\"Action\":\"s3:PutObject\",\"Resource\":\"arn:aws:s3:::$STATE_BUCKET/*\",\"Condition\":{\"StringNotEquals\":{\"s3:x-amz-server-side-encryption\":\"aws:kms\"}}}]}"
```

Finally, record the bucket and key in `terragrunt/account.hcl`:

```hcl
locals {
  account_name   = "cloudgeeks"
  aws_account_id = "898961940126"

  state_bucket  = "cloudgeeks-eks-blueprints-tfstate-898961940126"
  state_kms_key = "alias/terraform-state"
}
```

`root.hcl` derives every unit's state key from `path_relative_to_include()`, so
each unit lands at `env/dev/region/us-east-1/<layer>/terraform.tfstate` with no
per-unit backend configuration.
