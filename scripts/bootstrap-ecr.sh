#!/usr/bin/env bash

set -euo pipefail

aws_region="${AWS_REGION:-eu-north-1}"
ecr_repository="${ECR_REPOSITORY:-ci-cd-test}"
github_repository="${GITHUB_REPOSITORY:-sincerely008/ci-cd-test}"
ec2_instance_id="${EC2_INSTANCE_ID:?Set EC2_INSTANCE_ID to the deployment instance ID}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lifecycle_policy="$script_dir/../infra/ecr-lifecycle-policy.json"

command -v aws >/dev/null
command -v gh >/dev/null
test -f "$lifecycle_policy"

account_id="$(aws sts get-caller-identity --query Account --output text)"
repository_owner="${github_repository%%/*}"
repository_name="${github_repository##*/}"
repository_owner_id="$(gh api "repos/$github_repository" --jq '.owner.id')"
repository_id="$(gh api "repos/$github_repository" --jq '.id')"
github_subject="repo:${repository_owner}@${repository_owner_id}/${repository_name}@${repository_id}:ref:refs/heads/main"
repository_arn="arn:aws:ecr:${aws_region}:${account_id}:repository/${ecr_repository}"
oidc_provider_arn="arn:aws:iam::${account_id}:oidc-provider/token.actions.githubusercontent.com"
push_role_name="ci-cd-test-github-ecr-push"
pull_role_name="ci-cd-test-ec2-ecr-pull"

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

cat > "$temporary_dir/github-trust-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "${oidc_provider_arn}"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "${github_subject}"
      }
    }
  }]
}
EOF

cat > "$temporary_dir/ecr-push-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:CompleteLayerUpload",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart"
      ],
      "Resource": "${repository_arn}"
    },
    {
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    }
  ]
}
EOF

cat > "$temporary_dir/ec2-trust-policy.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

cat > "$temporary_dir/ecr-pull-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer"
      ],
      "Resource": "${repository_arn}"
    },
    {
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    }
  ]
}
EOF

if ! aws ecr describe-repositories --repository-names "$ecr_repository" --region "$aws_region" >/dev/null 2>&1; then
  aws ecr create-repository \
    --repository-name "$ecr_repository" \
    --image-tag-mutability MUTABLE \
    --image-scanning-configuration scanOnPush=true \
    --region "$aws_region" >/dev/null
fi
aws ecr put-lifecycle-policy \
  --repository-name "$ecr_repository" \
  --lifecycle-policy-text "file://$lifecycle_policy" \
  --region "$aws_region" >/dev/null

if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$oidc_provider_arn" >/dev/null 2>&1; then
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com >/dev/null
fi

if aws iam get-role --role-name "$push_role_name" >/dev/null 2>&1; then
  aws iam update-assume-role-policy \
    --role-name "$push_role_name" \
    --policy-document "file://$temporary_dir/github-trust-policy.json"
else
  aws iam create-role \
    --role-name "$push_role_name" \
    --assume-role-policy-document "file://$temporary_dir/github-trust-policy.json" >/dev/null
fi
aws iam put-role-policy \
  --role-name "$push_role_name" \
  --policy-name ecr-push-single-repository \
  --policy-document "file://$temporary_dir/ecr-push-policy.json"

instance_profile_arn="$(aws ec2 describe-iam-instance-profile-associations \
  --filters "Name=instance-id,Values=$ec2_instance_id" "Name=state,Values=associated" \
  --query 'IamInstanceProfileAssociations[0].IamInstanceProfile.Arn' \
  --output text \
  --region "$aws_region")"

if [[ "$instance_profile_arn" == "None" ]]; then
  if ! aws iam get-role --role-name "$pull_role_name" >/dev/null 2>&1; then
    aws iam create-role \
      --role-name "$pull_role_name" \
      --assume-role-policy-document "file://$temporary_dir/ec2-trust-policy.json" >/dev/null
  fi
  aws iam put-role-policy \
    --role-name "$pull_role_name" \
    --policy-name ecr-pull-single-repository \
    --policy-document "file://$temporary_dir/ecr-pull-policy.json"
  if ! aws iam get-instance-profile --instance-profile-name "$pull_role_name" >/dev/null 2>&1; then
    aws iam create-instance-profile --instance-profile-name "$pull_role_name" >/dev/null
    aws iam add-role-to-instance-profile \
      --instance-profile-name "$pull_role_name" \
      --role-name "$pull_role_name"
  fi
  for attempt in {1..12}; do
    if aws ec2 associate-iam-instance-profile \
      --instance-id "$ec2_instance_id" \
      --iam-instance-profile Name="$pull_role_name" \
      --region "$aws_region" >/dev/null 2>&1; then
      break
    fi
    if [[ "$attempt" == 12 ]]; then
      echo "Timed out waiting for the new IAM instance profile to become attachable." >&2
      exit 1
    fi
    sleep 5
  done
else
  instance_profile_name="${instance_profile_arn##*/}"
  existing_role_name="$(aws iam get-instance-profile \
    --instance-profile-name "$instance_profile_name" \
    --query 'InstanceProfile.Roles[0].RoleName' \
    --output text)"
  aws iam put-role-policy \
    --role-name "$existing_role_name" \
    --policy-name ecr-pull-single-repository \
    --policy-document "file://$temporary_dir/ecr-pull-policy.json"
fi

push_role_arn="arn:aws:iam::${account_id}:role/${push_role_name}"
gh secret set AWS_GITHUB_ACTIONS_ROLE_ARN --body "$push_role_arn"
gh variable set AWS_REGION --body "$aws_region"
gh variable set ECR_REPOSITORY --body "$ecr_repository"

printf 'ECR_REGISTRY=%s.dkr.ecr.%s.amazonaws.com\n' "$account_id" "$aws_region"
printf 'ECR_REPOSITORY=%s\n' "$ecr_repository"
printf 'GITHUB_OIDC_ROLE=%s\n' "$push_role_arn"
