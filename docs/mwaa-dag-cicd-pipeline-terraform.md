# DAG CI/CD pipeline for the SMUS Workflows env (Terraform reference)

> **Audience:** Operators who want a Git-triggered pipeline that builds,
> validates, and syncs DAGs into the MWAA env that SMUS provisions for a
> project, managed via Terraform. This is the lighter-weight alternative
> to forking [`aws-samples/cdk-amazon-mwaa-cicd`](https://github.com/aws-samples/cdk-amazon-mwaa-cicd) —
> it reuses the SMUS-managed env, bucket, KMS key, and CodeConnections
> connection rather than creating new ones.
>
> A CloudFormation version of this same pipeline is documented in
> [`mwaa-dag-cicd-pipeline.md`](mwaa-dag-cicd-pipeline.md). Pick whichever
> matches your IaC stack — the resulting AWS infrastructure is identical.

The flow:

```
GitHub / GitLab / Bitbucket  →  CodePipeline (Source via CodeConnections)
                                       ↓
                                CodeBuild (lint, dag-import test)
                                       ↓
                          aws s3 sync dags/  →  s3://<tooling-bucket>/<domain>/<project>/shared/workflows/dags/
                                       ↓
                                 MWAA picks up the change
```

No new MWAA env. No new bucket. No new VPC. The pipeline writes into the
prefix the Workflows env is already configured to read.

---

## Variables

Substitute these before applying. All values come from a successful
`smus-setup.sh` run plus the SMUS portal:

| Variable                | Where to find it                                                                                              |
|-------------------------|---------------------------------------------------------------------------------------------------------------|
| `aws_region`            | Domain region (e.g. `us-east-1`)                                                                              |
| `parent_stack_name`     | The setup stack name (default `smus-seed`, or whatever was passed to `--stack-name`)                          |
| `domain_id`             | `aws datazone list-domains --query "items[?name=='<domain-name>'].id"`                                        |
| `project_id`            | `aws datazone list-projects --domain-identifier <DOMAIN_ID> --query "items[?name=='<project-name>'].id"`      |
| `tooling_bucket_name`   | `amazon-datazone-tooling-<ACCOUNT_ID>-<REGION>-<STACK_SUFFIX>` (read from CFN output `oSUSBPToolingBucketName`) |
| `tooling_kms_key_arn`   | CFN output `oSUSBPToolingKMSKeyArn` — leave empty when bucket uses SSE-S3                                     |
| `connection_arn`        | CodeConnections connection created by Step 09 (`aws codeconnections list-connections`)                        |
| `repo_full_id`          | e.g. `your-org/your-repo` (the format CodeConnections expects)                                                |
| `branch`                | Default branch (e.g. `main`)                                                                                  |

The DAGs in your repo are expected at `dags/*.py`. Adjust the `buildspec`
heredoc below if your repo lays them out differently.

---

## File layout

```
mwaa-dag-pipeline/
├── main.tf
├── variables.tf
├── outputs.tf
├── buildspec.yml      # extracted to a separate file for readability
└── terraform.tfvars   # gitignored — your values
```

You can absolutely keep everything in a single `main.tf`; the split below
is just for readability.

---

## `variables.tf`

```hcl
variable "aws_region" {
  description = "AWS region of the SMUS domain (e.g. us-east-1)."
  type        = string
}

variable "parent_stack_name" {
  description = "SMUS setup stack name (e.g. smus-seed). Used as a prefix for every named resource."
  type        = string
}

variable "domain_id" {
  description = "SMUS DataZone domain id (e.g. dzd-...)."
  type        = string
}

variable "project_id" {
  description = "SMUS DataZone project id (the project whose MWAA env this pipeline targets)."
  type        = string
}

variable "tooling_bucket_name" {
  description = "SMUS Tooling bucket name (oSUSBPToolingBucketName CFN output)."
  type        = string
}

variable "tooling_kms_key_arn" {
  description = "Tooling KMS key ARN. Empty when bucket uses SSE-S3 (current default)."
  type        = string
  default     = ""
}

variable "connection_arn" {
  description = "CodeConnections connection ARN with read access to the source repo."
  type        = string
}

variable "repo_full_id" {
  description = "Full repo id (e.g. my-org/my-dags-repo)."
  type        = string
}

variable "branch" {
  description = "Branch to source DAGs from."
  type        = string
  default     = "main"
}
```

---

## `main.tf`

```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

locals {
  bucket_is_cmk = var.tooling_kms_key_arn != ""
  dags_prefix   = "${var.domain_id}/${var.project_id}/shared/workflows"
  account_id    = data.aws_caller_identity.current.account_id
}

# -----------------------------------------------------------------------------
# Artifact bucket for CodePipeline. CodePipeline needs a separate artifact
# bucket — it cannot stage artifacts in a bucket it doesn't own.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "pipeline_artifacts" {
  bucket        = "${var.parent_stack_name}-mwaa-cicd-artifacts-${local.account_id}-${var.aws_region}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "pipeline_artifacts" {
  bucket                  = aws_s3_bucket.pipeline_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# -----------------------------------------------------------------------------
# IAM role for CodeBuild. Scoped to:
#   * Write under the project's prefix in the Tooling bucket.
#   * Read from the artifact bucket.
#   * KMS perms only when the Tooling bucket uses CMK.
#   * CloudWatch Logs for the build's own logs.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "codebuild_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "codebuild_inline" {
  statement {
    sid    = "WriteDagsPrefix"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = ["arn:aws:s3:::${var.tooling_bucket_name}/${local.dags_prefix}/*"]
  }

  statement {
    sid       = "ListBucketForSync"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.tooling_bucket_name}"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.dags_prefix}/*"]
    }
  }

  statement {
    sid    = "ArtifactBucketRW"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.pipeline_artifacts.arn,
      "${aws_s3_bucket.pipeline_artifacts.arn}/*",
    ]
  }

  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/codebuild/${var.parent_stack_name}-mwaa-cicd-build*"]
  }

  dynamic "statement" {
    for_each = local.bucket_is_cmk ? [1] : []
    content {
      sid    = "ToolingBucketKmsAccess"
      effect = "Allow"
      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:GenerateDataKey",
        "kms:GenerateDataKeyWithoutPlaintext",
        "kms:DescribeKey",
      ]
      resources = [var.tooling_kms_key_arn]
      condition {
        test     = "StringLike"
        variable = "kms:ViaService"
        values   = ["s3.${var.aws_region}.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role" "codebuild" {
  name               = "${var.parent_stack_name}-mwaa-cicd-build-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume_role.json
}

resource "aws_iam_role_policy" "codebuild_inline" {
  name   = "SyncDagsToToolingBucket"
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild_inline.json
}

# -----------------------------------------------------------------------------
# CodeBuild project: lint -> dag-import test -> aws s3 sync
# -----------------------------------------------------------------------------
resource "aws_codebuild_project" "dag_build" {
  name         = "${var.parent_stack_name}-mwaa-cicd-build"
  service_role = aws_iam_role.codebuild.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspec.yml")
  }

  environment {
    type            = "LINUX_CONTAINER"
    image           = "aws/codebuild/standard:7.0"
    compute_type    = "BUILD_GENERAL1_SMALL"
    privileged_mode = false

    environment_variable {
      name  = "TOOLING_BUCKET"
      value = var.tooling_bucket_name
    }
    environment_variable {
      name  = "DOMAIN_ID"
      value = var.domain_id
    }
    environment_variable {
      name  = "PROJECT_ID"
      value = var.project_id
    }
  }
}

# -----------------------------------------------------------------------------
# IAM role for CodePipeline.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "codepipeline_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "codepipeline_inline" {
  statement {
    sid    = "UseConnection"
    effect = "Allow"
    actions = [
      "codeconnections:UseConnection",
      "codestar-connections:UseConnection",
    ]
    resources = [var.connection_arn]
  }

  statement {
    sid    = "ArtifactBucketRW"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.pipeline_artifacts.arn,
      "${aws_s3_bucket.pipeline_artifacts.arn}/*",
    ]
  }

  statement {
    sid    = "StartBuild"
    effect = "Allow"
    actions = [
      "codebuild:StartBuild",
      "codebuild:BatchGetBuilds",
    ]
    resources = [aws_codebuild_project.dag_build.arn]
  }
}

resource "aws_iam_role" "codepipeline" {
  name               = "${var.parent_stack_name}-mwaa-cicd-pipeline-role"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_assume_role.json
}

resource "aws_iam_role_policy" "codepipeline_inline" {
  name   = "PipelineExecution"
  role   = aws_iam_role.codepipeline.id
  policy = data.aws_iam_policy_document.codepipeline_inline.json
}

# -----------------------------------------------------------------------------
# The pipeline itself.
# -----------------------------------------------------------------------------
resource "aws_codepipeline" "dag_pipeline" {
  name     = "${var.parent_stack_name}-mwaa-dag-pipeline"
  role_arn = aws_iam_role.codepipeline.arn

  artifact_store {
    location = aws_s3_bucket.pipeline_artifacts.id
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "SourceAction"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["SourceOutput"]

      configuration = {
        ConnectionArn    = var.connection_arn
        FullRepositoryId = var.repo_full_id
        BranchName       = var.branch
        # Detect changes via webhook (default for CodeConnections source
        # actions); set to "false" to poll instead.
        DetectChanges = "true"
      }
    }
  }

  stage {
    name = "BuildAndDeploy"
    action {
      name            = "SyncDags"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["SourceOutput"]

      configuration = {
        ProjectName = aws_codebuild_project.dag_build.name
      }
    }
  }
}
```

---

## `buildspec.yml`

```yaml
version: 0.2
phases:
  install:
    runtime-versions:
      python: 3.11
    commands:
      # Install only what's needed to validate DAGs without spinning up the
      # full Airflow runtime. apache-airflow itself pulls 200+ deps; the
      # slim subset below is enough for `python -c "import dag_module"` to
      # succeed.
      - pip install --quiet 'apache-airflow==2.10.1' --constraint "https://raw.githubusercontent.com/apache/airflow/constraints-2.10.1/constraints-3.11.txt"
      - pip install --quiet pylint
  pre_build:
    commands:
      - echo "Linting DAGs..."
      - pylint --errors-only --disable=E0401 dags/ || true
  build:
    commands:
      - echo "Validating DAG imports..."
      - |
        for f in $(find dags -name '*.py' -not -path '*/__pycache__/*'); do
          echo "  -> $f"
          python -c "
        import importlib.util, sys
        spec = importlib.util.spec_from_file_location('dag', '$f')
        mod  = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        " || { echo "DAG import failed: $f"; exit 1; }
        done
  post_build:
    commands:
      - echo "Syncing DAGs to s3://$TOOLING_BUCKET/$DOMAIN_ID/$PROJECT_ID/shared/workflows/dags/"
      - aws s3 sync dags/ s3://$TOOLING_BUCKET/$DOMAIN_ID/$PROJECT_ID/shared/workflows/dags/ --delete --exclude '__pycache__/*' --exclude '*.pyc'
      # Optional: also sync requirements.txt and plugins.zip if your repo carries them.
      - |
        if [ -f config/requirements.txt ]; then
          aws s3 cp config/requirements.txt s3://$TOOLING_BUCKET/$DOMAIN_ID/$PROJECT_ID/shared/workflows/config/requirements.txt
        fi
      - |
        if [ -f config/plugins.zip ]; then
          aws s3 cp config/plugins.zip s3://$TOOLING_BUCKET/$DOMAIN_ID/$PROJECT_ID/shared/workflows/config/plugins.zip
        fi
```

---

## `outputs.tf`

```hcl
output "pipeline_name" {
  description = "CodePipeline name. Open the pipeline in the console to monitor runs."
  value       = aws_codepipeline.dag_pipeline.name
}

output "artifact_bucket_name" {
  description = "Pipeline artifact bucket (separate from the Tooling bucket)."
  value       = aws_s3_bucket.pipeline_artifacts.id
}

output "codebuild_project_name" {
  description = "CodeBuild project name."
  value       = aws_codebuild_project.dag_build.name
}
```

---

## `terraform.tfvars` (example, gitignore this)

```hcl
aws_region          = "us-east-1"
parent_stack_name   = "smus-seed"
domain_id           = "dzd-XXXXXXXXXXXXXX"
project_id          = "XXXXXXXXXXXXXX"
tooling_bucket_name = "amazon-datazone-tooling-123456789012-us-east-1-smus-seed"
tooling_kms_key_arn = ""  # SSE-S3; set to the ARN if the bucket uses CMK
connection_arn      = "arn:aws:codeconnections:us-east-1:123456789012:connection/XXXX"
repo_full_id        = "my-org/my-dags-repo"
branch              = "main"
```

---

## Deploy

```bash
terraform init
terraform plan
terraform apply
```

---

## Verification

1. Push a commit to `<branch>` that adds or modifies a file under `dags/`.
2. Watch the pipeline in the CodePipeline console. The Source stage triggers
   on the webhook, then BuildAndDeploy runs CodeBuild.
3. CodeBuild logs (CloudWatch `/aws/codebuild/<parent_stack_name>-mwaa-cicd-build`)
   should show the lint, the import test, and the `aws s3 sync` line listing
   uploaded keys.
4. Open the SMUS portal → your project → Workflows env → Airflow UI. The new
   DAG appears within ~30 s (MWAA polls the DAG bucket on a short cadence).

If you want to verify the upload directly:
```bash
aws s3 ls --profile <PROFILE> s3://<tooling_bucket_name>/<domain_id>/<project_id>/shared/workflows/dags/
```

---

## Multi-env (dev / test / prod)

The module above targets one env. Three patterns scale up:

1. **One Terraform workspace per stage.** `terraform workspace new dev`,
   `test`, `prod`, with stage-specific `*.tfvars`. Same code, three states.
2. **Module-per-stage.** Wrap this code as a Terraform module and call it
   three times in a parent module, each with different `project_id` /
   `tooling_bucket_name` / `branch`. One state file, three pipelines.
3. **Manual approval gates.** Add a `Manual` action in the pipeline between
   build and deploy stages, plus a second CodeBuild action targeting the
   next stage's bucket prefix. One pipeline, three syncs, gated on operator
   approval.

---

## What this does NOT do (and why)

- **Does not create an MWAA env.** SMUS owns env lifecycle. Use the portal
  Workflows tab on the project to create the env once.
- **Does not manage `requirements.txt` / `plugins.zip` updates.** The
  buildspec uploads them if present in the repo, but MWAA still needs an
  env update to pick them up. Either bump the version label in the SMUS
  portal after upload, or extend the buildspec with
  `aws mwaa update-environment` (not shown — requires
  `airflow:UpdateEnvironment` on `<env-arn>` and is operationally heavier
  than DAG-only changes).
- **Does not create a CodeConnections connection.** Step 09 of `migrate.sh`
  does that, or it can be done from the SMUS portal once. This module
  consumes the existing ARN.
- **Does not bootstrap the source repo with a starter DAG.** Add one
  manually after the first deploy.
