#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Terraform Project Bootstrap Script
# 用法: ./init.sh <project_name> <gcp_project_id> <github_owner> <github_repo> [region] [sa_email]
#
# 範例:
#   ./init.sh atlas-p6 my-gcp-project my-org my-repo asia-east1
# ============================================

if [ $# -lt 4 ]; then
  echo "用法: $0 <project_name> <gcp_project_id> <github_owner> <github_repo> [region] [sa_email]"
  echo "範例: $0 atlas-p6 my-gcp-project my-org my-repo asia-east1"
  exit 1
fi

PROJECT_NAME="$1"
GCP_PROJECT_ID="$2"
GITHUB_OWNER="$3"
GITHUB_REPO="$4"
REGION="${5:-asia-east1}"
SA_EMAIL="${6:-cloud-build-sa-tester@${GCP_PROJECT_ID}.iam.gserviceaccount.com}"

BUCKET_NAME="${GCP_PROJECT_ID}-tf-state"
STATE_PREFIX="${PROJECT_NAME}"
CONNECTION_NAME="${GITHUB_OWNER}-connection"
REMOTE_URI="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git"

echo "=========================================="
echo "Terraform Project Bootstrap"
echo "  Project Name : ${PROJECT_NAME}"
echo "  GCP Project  : ${GCP_PROJECT_ID}"
echo "  GitHub Repo  : ${GITHUB_OWNER}/${GITHUB_REPO}"
echo "  Region       : ${REGION}"
echo "=========================================="

if [ -d "${PROJECT_NAME}" ]; then
  echo "錯誤:資料夾 ${PROJECT_NAME} 已經存在"
  exit 1
fi

if ! gcloud auth list --filter="status:ACTIVE" --format="value(account)" | grep -q .; then
  echo "錯誤:尚未登入 gcloud,請先執行 gcloud auth login"
  exit 1
fi

# ============================================
# 步驟 1: 檢查 / 建立 GitHub Connection(這一步可能需要手動介入)
# ============================================
echo ""
echo "[1/7] 檢查 GitHub Connection: ${CONNECTION_NAME}..."

if gcloud builds connections describe "${CONNECTION_NAME}" \
    --region="${REGION}" \
    --project="${GCP_PROJECT_ID}" &>/dev/null; then
  echo "  → Connection 已存在,略過"
else
  echo "  → Connection 不存在,需要先建立"
  echo ""
  echo "  請前往以下網址完成 GitHub 授權連接:"
  echo "  https://console.cloud.google.com/cloud-build/repositories/2nd-gen?project=${GCP_PROJECT_ID}"
  echo ""
  echo "  步驟:"
  echo "    1. 點選 'Create host connection'"
  echo "    2. 選擇 GitHub,並命名為: ${CONNECTION_NAME}"
  echo "    3. 完成 GitHub App 授權(授權存取 ${GITHUB_OWNER} 這個 org/帳號)"
  echo ""
  read -p "  完成後,請按 Enter 繼續..." _

  # 再次確認 connection 是否真的建立成功
  if ! gcloud builds connections describe "${CONNECTION_NAME}" \
      --region="${REGION}" \
      --project="${GCP_PROJECT_ID}" &>/dev/null; then
    echo "  錯誤:仍然找不到 connection '${CONNECTION_NAME}',請確認是否命名一致,或重新執行此腳本"
    exit 1
  fi
  echo "  → Connection 確認建立完成"
fi

# ============================================
# 步驟 2: 檢查 / 註冊 Repository
# ============================================
echo ""
echo "[2/7] 檢查 / 註冊 Repository: ${GITHUB_REPO}..."

if gcloud builds repositories describe "${GITHUB_REPO}" \
    --connection="${CONNECTION_NAME}" \
    --region="${REGION}" \
    --project="${GCP_PROJECT_ID}" &>/dev/null; then
  echo "  → Repository 已註冊,略過"
else
  gcloud builds repositories create "${GITHUB_REPO}" \
    --connection="${CONNECTION_NAME}" \
    --region="${REGION}" \
    --project="${GCP_PROJECT_ID}" \
    --remote-uri="${REMOTE_URI}"
  echo "  → Repository 註冊完成"
fi

REPOSITORY_ID="projects/${GCP_PROJECT_ID}/locations/${REGION}/connections/${CONNECTION_NAME}/repositories/${GITHUB_REPO}"

# ============================================
# 步驟 3: 建立資料夾結構
# ============================================
echo ""
echo "[3/7] 建立資料夾結構..."
mkdir -p "${PROJECT_NAME}/modules"

# ============================================
# 步驟 4: 建立 GCS bucket
# ============================================
echo ""
echo "[4/7] 檢查 / 建立 GCS bucket: ${BUCKET_NAME}..."

if gsutil ls -b "gs://${BUCKET_NAME}" &>/dev/null; then
  echo "  → Bucket 已存在,略過"
else
  gsutil mb -p "${GCP_PROJECT_ID}" -l "${REGION}" "gs://${BUCKET_NAME}"
  gsutil versioning set on "gs://${BUCKET_NAME}"
  echo "  → Bucket 建立完成"
fi

# ============================================
# 步驟 5: 產生 Terraform 檔案
# ============================================
echo ""
echo "[5/7] 產生 Terraform 檔案..."

cat > "${PROJECT_NAME}/backend.tf" <<EOF
terraform {
  backend "gcs" {
    bucket = "${BUCKET_NAME}"
    prefix = "${STATE_PREFIX}"
  }
}
EOF

cat > "${PROJECT_NAME}/provider.tf" <<EOF
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
EOF

cat > "${PROJECT_NAME}/main.tf" <<EOF
# ${PROJECT_NAME} 主要資源定義
# module "cicd_app" {
#   source     = "../modules/cicd-app"
#   project_id = var.project_id
#   region     = var.region
#   app_name   = "${PROJECT_NAME}"
# }
EOF

cat > "${PROJECT_NAME}/variables.tf" <<EOF
variable "project_id" {
  type    = string
  default = "${GCP_PROJECT_ID}"
}

variable "region" {
  type    = string
  default = "${REGION}"
}
EOF

cat > "${PROJECT_NAME}/outputs.tf" <<EOF
# output "cloud_run_url" {
#   value = module.cicd_app.cloud_run_url
# }
EOF

# ============================================
# 步驟 6: 建立 Plan Trigger
# ============================================
echo ""
echo "[6/7] 建立 Plan Trigger..."

if gcloud builds triggers describe "${PROJECT_NAME}-plan" --region="${REGION}" --project="${GCP_PROJECT_ID}" &>/dev/null; then
  echo "  → Trigger 已存在,略過"
else
  gcloud builds triggers create pull-request \
    --name="${PROJECT_NAME}-plan" \
    --region="${REGION}" \
    --project="${GCP_PROJECT_ID}" \
    --repository="${REPOSITORY_ID}" \
    --pull-request-pattern="^main$" \
    --build-config="cloudbuild-plan.yaml" \
    --service-account="projects/${GCP_PROJECT_ID}/serviceAccounts/${SA_EMAIL}" \
    --included-files="${PROJECT_NAME}/**" \
    --substitutions="_TF_DIR=${PROJECT_NAME}"
  echo "  → Plan trigger 建立完成"
fi

# ============================================
# 步驟 7: 建立 Apply Trigger
# ============================================
echo ""
echo "[7/7] 建立 Apply Trigger..."

if gcloud builds triggers describe "${PROJECT_NAME}-apply" --region="${REGION}" --project="${GCP_PROJECT_ID}" &>/dev/null; then
  echo "  → Trigger 已存在,略過"
else
  gcloud builds triggers create push \
    --name="${PROJECT_NAME}-apply" \
    --region="${REGION}" \
    --project="${GCP_PROJECT_ID}" \
    --repository="${REPOSITORY_ID}" \
    --branch-pattern="^main$" \
    --build-config="cloudbuild-apply.yaml" \
    --service-account="projects/${GCP_PROJECT_ID}/serviceAccounts/${SA_EMAIL}" \
    --included-files="${PROJECT_NAME}/**" \
    --substitutions="_TF_DIR=${PROJECT_NAME}" \
    --require-approval
  echo "  → Apply trigger 建立完成(需人工核准)"
fi

echo ""
echo "=========================================="
echo "完成!"
echo "  ${PROJECT_NAME}/ 已建立"
echo "  Plan trigger : ${PROJECT_NAME}-plan"
echo "  Apply trigger: ${PROJECT_NAME}-apply"
echo "=========================================="
echo ""
echo "接下來:"
echo "  1. git add ${PROJECT_NAME}/ && git commit -m 'init ${PROJECT_NAME}'"
echo "  2. git push,開一個 PR 測試 plan trigger"
echo "  3. merge 後到 Console 核准 apply"