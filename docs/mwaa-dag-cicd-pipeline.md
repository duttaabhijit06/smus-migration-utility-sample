# DAG CI/CD pipeline for the SMUS Workflows env (CloudFormation reference)

> **Audience:** Operators who want a Git-triggered pipeline that builds,
> validates, and syncs DAGs into the MWAA env that SMUS provisions for a
> project. This is the lighter-weight alternative to forking
> [`aws-samples/cdk-amazon-mwaa-cicd`](https://github.com/aws-samples/cdk-amazon-mwaa-cicd) —
> it reuses the SMUS-managed env, bucket, KMS key, and CodeConnections
> connection rather than creating new ones.

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

## Placeholders

Substitute these before applying. All values come from a successful
`smus-setup.sh` run plus the SMUS portal:

| Placeholder              | Where to find it                                                                                              |
|--------------------------|---------------------------------------------------------------------------------------------------------------|
| `<ACCOUNT_ID>`           | `aws sts get-caller-identity --query Account`                                                                 |
| `<REGION>`               | Domain region (e.g. `us-east-1`)                                                                              |
| `<STACK_NAME>`           | The setup stack name (default `smus-seed`, or whatever was passed to `--stack-name`)                          |
| `<DOMAIN_ID>`            | `aws datazone list-domains --query "items[?name=='<domain-name>'].id"`                                        |
| `<PROJECT_ID>`           | `aws datazone list-projects --domain-identifier <DOMAIN_ID> --query "items[?name=='<project-name>'].id"`      |
| `<TOOLING_BUCKET>`       | `amazon-datazone-tooling-<ACCOUNT_ID>-<REGION>-<STACK_SUFFIX>` (read from CFN output `oSUSBPToolingBucketName`) |
| `<TOOLING_KMS_KEY_ARN>`  | CFN output `oSUSBPToolingKMSKeyArn` — needed only if you re-introduce CMK on the bucket                       |
| `<CONNECTION_ARN>`       | CodeConnections connection created by Step 09 (`aws codeconnections list-connections`)                        |
| `<REPO_FULL_ID>`         | e.g. `your-org/your-repo` (the format CodeConnections expects)                                                |
| `<BRANCH>`               | Default branch (e.g. `main`)                                                                                  |

The DAGs in your repo are expected at `dags/*.py`. Adjust the
`PIPELINE_BUILDSPEC` `BUILD_PHASES` block below if your repo lays them out
differently.

---

## Single CFN template

Save as `mwaa-dag-pipeline.yaml` and deploy with:

```bash
aws cloudformation deploy \
  --stack-name <STACK_NAME>-mwaa-dag-pipeline \
  --template-file mwaa-dag-pipeline.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    ParentStackName=<STACK_NAME> \
    ToolingBucketName=<TOOLING_BUCKET> \
    ToolingKmsKeyArn=<TOOLING_KMS_KEY_ARN> \
    DomainId=<DOMAIN_ID> \
    ProjectId=<PROJECT_ID> \
    ConnectionArn=<CONNECTION_ARN> \
    RepoFullId=<REPO_FULL_ID> \
    Branch=<BRANCH>
```

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >-
  DAG CI/CD pipeline that syncs DAGs from a Git repo (via CodeConnections)
  into the SMUS-managed Tooling bucket prefix that the project's MWAA env
  reads from. No MWAA env, bucket, VPC, or KMS key created here — all of
  those are owned by the SMUS master stack.

Parameters:
  ParentStackName:
    Type: String
    Description: >-
      Name of the SMUS setup stack (e.g. smus-seed). Used as a prefix for
      every named resource so multiple projects in the same account can
      coexist.
  ToolingBucketName:
    Type: String
    Description: SMUS Tooling bucket name (oSUSBPToolingBucketName output).
  ToolingKmsKeyArn:
    Type: String
    Default: ''
    Description: >-
      Tooling KMS key ARN. Leave empty when the bucket uses SSE-S3 (the
      current default). Provide the ARN if you re-introduce CMK on the
      bucket — the CodeBuild role needs kms:GenerateDataKey to write
      CMK-encrypted objects.
  DomainId:
    Type: String
    Description: SMUS DataZone domain id (e.g. dzd-...).
  ProjectId:
    Type: String
    Description: SMUS DataZone project id (the project whose MWAA env this pipeline targets).
  ConnectionArn:
    Type: String
    Description: CodeConnections connection ARN with read access to the source repo.
  RepoFullId:
    Type: String
    Description: 'Full repo id (e.g. my-org/my-dags-repo).'
  Branch:
    Type: String
    Default: main
    Description: Branch to source DAGs from.

Conditions:
  ToolingBucketIsCMK: !Not [!Equals [!Ref ToolingKmsKeyArn, '']]

Resources:
  # ---------------------------------------------------------------------------
  # Artifact bucket for CodePipeline. CodePipeline requires a separate
  # artifact bucket — it cannot stage artifacts in a bucket it doesn't own.
  # ---------------------------------------------------------------------------
  rPipelineArtifactBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Delete
    UpdateReplacePolicy: Delete
    Properties:
      BucketName: !Sub '${ParentStackName}-mwaa-cicd-artifacts-${AWS::AccountId}-${AWS::Region}'
      VersioningConfiguration:
        Status: Enabled
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: AES256

  # ---------------------------------------------------------------------------
  # IAM role for CodeBuild. Scoped to:
  #   * Write under the project's prefix in the Tooling bucket.
  #   * Read from the artifact bucket.
  #   * KMS perms only when the Tooling bucket uses CMK.
  #   * CloudWatch Logs for the build's own logs.
  # ---------------------------------------------------------------------------
  rCodeBuildRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub '${ParentStackName}-mwaa-cicd-build-role'
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: codebuild.amazonaws.com
            Action: sts:AssumeRole
      Policies:
        - PolicyName: SyncDagsToToolingBucket
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Sid: WriteDagsPrefix
                Effect: Allow
                Action:
                  - s3:PutObject
                  - s3:DeleteObject
                  - s3:GetObject
                  - s3:GetObjectVersion
                Resource:
                  - !Sub 'arn:aws:s3:::${ToolingBucketName}/${DomainId}/${ProjectId}/shared/workflows/*'
              - Sid: ListBucketForSync
                Effect: Allow
                Action: s3:ListBucket
                Resource: !Sub 'arn:aws:s3:::${ToolingBucketName}'
                Condition:
                  StringLike:
                    s3:prefix:
                      - !Sub '${DomainId}/${ProjectId}/shared/workflows/*'
              - Sid: ArtifactBucketRW
                Effect: Allow
                Action:
                  - s3:GetObject
                  - s3:GetObjectVersion
                  - s3:PutObject
                  - s3:ListBucket
                Resource:
                  - !GetAtt rPipelineArtifactBucket.Arn
                  - !Sub '${rPipelineArtifactBucket.Arn}/*'
              - Sid: CloudWatchLogs
                Effect: Allow
                Action:
                  - logs:CreateLogGroup
                  - logs:CreateLogStream
                  - logs:PutLogEvents
                Resource: !Sub 'arn:aws:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/codebuild/${ParentStackName}-mwaa-cicd-build*'
              - !If
                - ToolingBucketIsCMK
                - Sid: ToolingBucketKmsAccess
                  Effect: Allow
                  Action:
                    - kms:Encrypt
                    - kms:Decrypt
                    - kms:GenerateDataKey*
                    - kms:DescribeKey
                  Resource: !Ref ToolingKmsKeyArn
                  Condition:
                    StringLike:
                      kms:ViaService: !Sub 's3.${AWS::Region}.amazonaws.com'
                - !Ref AWS::NoValue

  # ---------------------------------------------------------------------------
  # CodeBuild project: lint -> dag-import test -> aws s3 sync
  # ---------------------------------------------------------------------------
  rDagBuild:
    Type: AWS::CodeBuild::Project
    Properties:
      Name: !Sub '${ParentStackName}-mwaa-cicd-build'
      ServiceRole: !GetAtt rCodeBuildRole.Arn
      Artifacts:
        Type: CODEPIPELINE
      Source:
        Type: CODEPIPELINE
        BuildSpec: |
          version: 0.2
          phases:
            install:
              runtime-versions:
                python: 3.11
              commands:
                # Install only what's needed to validate DAGs without
                # spinning up the full Airflow runtime. apache-airflow
                # itself pulls 200+ deps; the slim subset below is enough
                # for `python -c "import dag_module"` to succeed.
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
      Environment:
        Type: LINUX_CONTAINER
        Image: aws/codebuild/standard:7.0
        ComputeType: BUILD_GENERAL1_SMALL
        EnvironmentVariables:
          - Name: TOOLING_BUCKET
            Value: !Ref ToolingBucketName
          - Name: DOMAIN_ID
            Value: !Ref DomainId
          - Name: PROJECT_ID
            Value: !Ref ProjectId

  # ---------------------------------------------------------------------------
  # IAM role for CodePipeline. Trusts codepipeline; can use the
  # CodeConnections connection, write the artifact bucket, and start the
  # CodeBuild project.
  # ---------------------------------------------------------------------------
  rCodePipelineRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub '${ParentStackName}-mwaa-cicd-pipeline-role'
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: codepipeline.amazonaws.com
            Action: sts:AssumeRole
      Policies:
        - PolicyName: PipelineExecution
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Sid: UseConnection
                Effect: Allow
                Action:
                  - codeconnections:UseConnection
                  - codestar-connections:UseConnection
                Resource: !Ref ConnectionArn
              - Sid: ArtifactBucketRW
                Effect: Allow
                Action:
                  - s3:GetObject
                  - s3:GetObjectVersion
                  - s3:PutObject
                  - s3:ListBucket
                Resource:
                  - !GetAtt rPipelineArtifactBucket.Arn
                  - !Sub '${rPipelineArtifactBucket.Arn}/*'
              - Sid: StartBuild
                Effect: Allow
                Action:
                  - codebuild:StartBuild
                  - codebuild:BatchGetBuilds
                Resource: !GetAtt rDagBuild.Arn

  # ---------------------------------------------------------------------------
  # The pipeline itself.
  # ---------------------------------------------------------------------------
  rPipeline:
    Type: AWS::CodePipeline::Pipeline
    Properties:
      Name: !Sub '${ParentStackName}-mwaa-dag-pipeline'
      RoleArn: !GetAtt rCodePipelineRole.Arn
      ArtifactStore:
        Type: S3
        Location: !Ref rPipelineArtifactBucket
      Stages:
        - Name: Source
          Actions:
            - Name: SourceAction
              ActionTypeId:
                Category: Source
                Owner: AWS
                Provider: CodeStarSourceConnection
                Version: '1'
              Configuration:
                ConnectionArn: !Ref ConnectionArn
                FullRepositoryId: !Ref RepoFullId
                BranchName: !Ref Branch
                # Detect changes via webhook (default for CodeConnections
                # source actions); set to false to poll instead.
                DetectChanges: 'true'
              OutputArtifacts:
                - Name: SourceOutput
              RunOrder: 1
        - Name: BuildAndDeploy
          Actions:
            - Name: SyncDags
              ActionTypeId:
                Category: Build
                Owner: AWS
                Provider: CodeBuild
                Version: '1'
              Configuration:
                ProjectName: !Ref rDagBuild
              InputArtifacts:
                - Name: SourceOutput
              RunOrder: 1

Outputs:
  PipelineName:
    Description: CodePipeline name. Open the pipeline in the console to monitor runs.
    Value: !Ref rPipeline
  ArtifactBucketName:
    Description: Pipeline artifact bucket (separate from the Tooling bucket).
    Value: !Ref rPipelineArtifactBucket
  CodeBuildProjectName:
    Description: CodeBuild project name.
    Value: !Ref rDagBuild
```

---

## Verification

1. Push a commit to `<BRANCH>` that adds or modifies a file under `dags/`.
2. Watch the pipeline in the CodePipeline console. The Source stage triggers
   on the webhook, then BuildAndDeploy runs CodeBuild.
3. CodeBuild logs (CloudWatch `/aws/codebuild/<STACK>-mwaa-cicd-build`) should
   show the lint, the import test, and the `aws s3 sync` line listing
   uploaded keys.
4. Open the SMUS portal → your project → Workflows env → Airflow UI. The new
   DAG appears within ~30 s (MWAA polls the DAG bucket on a short cadence).

If you want to verify the upload directly:
```bash
aws s3 ls --profile <PROFILE> s3://<TOOLING_BUCKET>/<DOMAIN_ID>/<PROJECT_ID>/shared/workflows/dags/
```

---

## Multi-env (dev / test / prod)

The template above targets one env. Three patterns scale up:

1. **One stack per stage.** Deploy this template three times with different
   `ParentStackName`, `ProjectId`, and `ToolingBucketName`. Cleanest
   isolation; redundant pipelines.
2. **Manual approval gates.** Add `Stages` with
   `Provider: Manual` between BuildAndDeploy stages, plus a second CodeBuild
   action targeting the next stage's bucket prefix. One pipeline, three
   syncs, gated on operator approval.
3. **Branch-per-stage.** Deploy three pipelines, each targeting a different
   `Branch` (`dev`, `test`, `prod`) but the same template.

---

## What this does NOT do (and why)

- **Does not create an MWAA env.** SMUS owns env lifecycle. Use the portal
  Workflows tab on the project to create the env once.
- **Does not manage `requirements.txt` / `plugins.zip` updates.** The
  buildspec uploads them if present in the repo, but MWAA still needs an
  env update to pick them up. Either bump the version label in the SMUS
  portal after upload, or extend the buildspec with
  `aws mwaa update-environment` (not shown — requires `airflow:UpdateEnvironment`
  on `<env-arn>` and is operationally heavier than DAG-only changes).
- **Does not create a CodeConnections connection.** Step 09 of `migrate.sh`
  does that, or it can be done from the SMUS portal once. This template
  consumes the existing ARN.
- **Does not bootstrap the source repo with a starter DAG.** Add one
  manually after the first deploy.
