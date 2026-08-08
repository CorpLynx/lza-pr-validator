# LZA Pull Request Validation Engine

This bundle contains the files required to implement a concurrent, S3-backed validation pipeline for Landing Zone Accelerator (LZA) configuration repositories.

## Overview
This architecture uses GitHub Actions to package your LZA configuration and AWS CodeBuild to execute the heavy validation logic. It runs three layers of checks:
1.  **YAML Linting**: Verifies syntax using `yamllint`.
2.  **Schema Validation**: Verifies structure using LZA's `yarn validate-config`.
3.  **CDK Synthesis**: Concurrently generates CloudFormation templates for the `prepare`, `security`, and `customizations` stages.

## Deployment Instructions

### Step 1: Deploy the CloudFormation Template
1.  Deploy `lza-validator-pipeline.yaml` in your AWS Management Account (or delegated administrator account) in your primary LZA region.
2.  Provide your GitHub Organization/Repository name (e.g., `my-org/lza-config`) and the LZA version deployed in your environment.
3.  Once the deployment is complete, navigate to the **Outputs** tab of the CloudFormation stack and copy the values for:
    *   `ValidationS3BucketName`
    *   `GitHubActionsRoleArn`

### Step 2: Add Files to Your Configuration Repository
1.  Copy `validate-lza.sh` and `buildspec.yml` into the **root directory** of your LZA configuration repository.
2.  Ensure `validate-lza.sh` is executable. You can set this locally using:
    ```bash
    chmod +x validate-lza.sh
    ```

### Step 3: Configure GitHub Actions
1.  Copy `.github/workflows/validate-pr.yml` to the exact path `.github/workflows/validate-pr.yml` in your repository.
2.  Open `.github/workflows/validate-pr.yml` and update the environment variables to match your CloudFormation stack outputs:
    ```yaml
    env:
      AWS_REGION: "us-east-1" # Update if using a different region
      S3_BUCKET: "your-ValidationS3BucketName-output"
      GHA_ROLE_ARN: "your-GitHubActionsRoleArn-output"
    ```

### Step 4: Commit and Push
Commit all added files to your repository. Any new Pull Requests opened against the `main` branch will automatically trigger this validation pipeline.