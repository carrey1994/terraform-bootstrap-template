#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Terraform Project Bootstrap Script
#
# 用法:
#   ./init.sh <project_name> <gcp_project_id> <github_owner> <github_repo> [region] [sa_email]
#
# 範例:
#   ./init.sh atlas-p6 my-gcp-project-id my-org atlas-p6-repo asia-east1
#
# 功能:
#   1. 檢查/建立 GitHub 2nd-gen Connection(需要人工完成 OAuth 授權)
#   2. 檢查/註冊 Repository
#   3. 建立 Terraform project 資料夾結構(backend.tf / provider.tf / main.tf / variables.tf / outputs.tf)
#   4. 建立 GCS bucket 作為 terraform state backend
#   5. 建立 Cloud Build Plan Trigger(PR 觸發)
#   6. 建立 Cloud Build Apply Trigger(merge 後觸發,需人工核准)
# ============================================

# --------------------------------------------
# 0. 參數檢查與初始化
# --------------------------------------------
if [ $# -lt 4 ]; then
  echo "用法: $0 <project_name> <gcp_project_id> <github_owner> <github_repo> [region] [sa_email]"
  echo "範例: $0 atlas-p6 my-gcp-project-id my-org atlas-p6-repo asia-east1"
  exit 1
fi

PROJECT_NAME="$1"
GCP_PROJECT_ID="$2"
GITHUB_OWNER="$3"
GITHUB_REPO="$4"
REGION="${5:-asia-east1}"
SA_EMAIL="${6:-cloud-build-sa-tester@${GCP_PROJECT_ID}.iam.gserviceaccount.com}"

# 防呆:確認所有必要變數都不是空字串
for var_name in PROJECT_NAME GCP_PROJECT_ID GITHUB_OWNER GITHUB_REPO REGION SA_EMAIL; do
  var_value="${!var_name}"
  if [ -z "${var_value}" ]; then
    echo "錯誤: 變數 ${var_name} 為空,無法繼續執行"
    exit 1
  fi
done

BUCKET_NAME="${GCP_PROJECT_ID}-tf-state"
STATE_PREFIX="${PROJECT_NAME}"
CONNECTION_NAME="${GITHUB_OWNER}-connection"
REMOTE_URI="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git"
REPOSITORY_ID="projects/${GCP_PROJECT_ID}/locations/${REGION}/connections/${CONNECTION_NAME}/repositories/${GITHUB_REPO}"

echo "=========================================="
echo "Terraform Project Bootstrap"
echo "  Project Name      : ${PROJECT_NAME}"
echo "  GCP Project ID    : ${GCP_PROJECT_ID}"
echo "  GitHub Repo       : ${GITHUB_OWNER}/${GITHUB_REPO}"
echo "  Region            : ${REGION}"
echo "  Service Account   : ${SA_EMAIL}"
echo "  State Bucket      : ${BUCKET_NAME}"
echo "  Connection Name   : ${CONNECTION_NAME}"
echo "=========================================="

# --------------------------------------------
# 前置檢查
# --------------------------------------------
if [ -d "${PROJECT_NAME}" ]; then
  echo "錯誤: 資料夾 ${PROJECT_NAME} 已經存在,請確認後手動處理"
  exit 1
fi

if ! command -v gcloud &>/dev/null; then
  echo "錯誤: 找不到 gcloud CLI,請先安裝 Google Cloud SDK"
  exit 1
fi

if ! command -v gsutil &>/dev/null; then
  echo "錯誤: 找不到 gsutil,請確認 Google Cloud SDK 安裝完整"
  exit 1
fi

ACTIVE_ACCOUNT=$(gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>/dev/null || true)
if [ -z "${ACTIVE_ACCOUNT}" ]; then
  echo "錯誤: 尚未登入 gcloud,請先執行: gcloud auth login"
  exit 1
fi
echo ""
echo "目前登入帳號: ${ACTIVE_ACCOUNT}"

# 確認可以存取這個 GCP project
if ! gcloud projects describe "${GCP_PROJECT_ID}" &>/dev/null; then
  echo "錯誤: 無法存取 GCP project '${GCP_PROJECT_ID}',請確認 project ID 正確且你有權限"
  exit 1
fi

# --------------------------------------------
# 步驟 1: 檢查 / 建立 GitHub Connection
# --------------------------------------------
echo ""
echo "[1/7] 檢查 GitHub Connection: ${CONNECTION_NAME}..."

CONNECTION_EXISTS=false
if gcloud builds connections describe "${CONNECTION_NAME}" \
    --region="${REGION}" \
    --project="${GCP_PROJECT_ID}" &>/dev/null; then
  CONNECTION_EXISTS=true
fi

if [ "${CONNECTION_EXISTS}" = false ]; then
  echo "  → Connection 不存在,建立中(尚未授權狀態)..."
  gcloud builds connections create github \
    "${CONNECTION_NAME}" \
    --region="${REGION}" \
    --project="${GCP_PROJECT_ID}"
fi

echo "  檢查授權狀態..."

INSTALL_STATE=$(gcloud builds connections describe "${CONNECTION_NAME}" \
  --region="${REGION}" \
  --project="${GCP_PROJECT_ID}" \
  --format="value(installationState.stage)" 2>/dev/null || echo "UNKNOWN")

if [ "${INSTALL_STATE}" != "COMPLETE" ]; then
  echo ""
  echo "  ⚠ 尚未完成 GitHub App 授權(目前狀態: ${INSTALL_STATE})"
  echo ""
  echo "  請前往以下網址完成授權:"
  echo "  https://console.cloud.google.com/cloud-build/repositories/2nd-gen?project=${GCP_PROJECT_ID}"
  echo ""
  echo "  步驟:"
  echo "    1. 找到 connection: ${CONNECTION_NAME}"
  echo "    2. 完成 GitHub App 安裝/授權流程"
  echo "    3. 確認授權存取 ${GITHUB_OWNER} 這個 org/帳號下的 repository"
  echo ""
  echo "  等待授權完成中(每 10 秒檢查一次,最多等待 10 分鐘)..."

  MAX_WAIT=60
  COUNT=0

  while [ "${INSTALL_STATE}" != "COMPLETE" ]; do
    if [ "${COUNT}" -ge "${MAX_WAIT}" ]; then
      echo ""
      echo "  錯誤: 等待逾時,授權仍未完成(目前狀態: ${INSTALL_STATE})"
      echo "  請完成授權後,重新執行此腳本"
      exit 1
    fi

    sleep 10
    COUNT=$((COUNT + 1))

    SET_RESULT=$(gcloud builds connections describe "${CONNECTION_NAME}" \
      --region="${REGION}" \
      --project="${GCP_PROJECT_ID}" \
      --format="value(installationState.stage)" 2>&1) || true

    if [ -z "${SET_RESULT}" ]; then
      INSTALL_STATE="UNKNOWN"
    else
      INSTALL_STATE="${SET_RESULT}"
    fi

    echo "  ...仍在等待(狀態: ${INSTALL_STATE}, 已等待 $((COUNT * 10)) 秒)"
  done

  echo ""
  echo "  ✓ 授權已完成!"
else
  echo "  → Connection 已完成授權,略過"
fi

# --------------------------------------------
# 步驟 2: 檢查 / 註冊 Repository
# --------------------------------------------
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

# --------------------------------------------
# 步驟 3: 建立資料夾結構
# --------------------------------------------
echo ""
echo "[3/7] 建立資料夾結構..."
mkdir -p "${PROJECT_NAME}/modules"
echo "  → ${PROJECT_NAME}/ 建立完成"

# --------------------------------------------
# 步驟 4: 建立 GCS bucket
# --------------------------------------------
echo ""
echo "[4/7] 檢查 / 建立 GCS bucket: ${BUCKET_NAME}..."

if gsutil ls -b "gs://${BUCKET_NAME}" &>/dev/null; then
  echo "  → Bucket 已存在,略過建立"
else
  gsutil mb -p "${GCP_PROJECT_ID}" -l "${REGION}" "gs://${BUCKET_NAME}"
  gsutil versioning set on "gs://${BUCKET_NAME}"
  echo "  → Bucket 建立完成,已啟用版本控制"
fi

# --------------------------------------------
# 步驟 5: 產生 Terraform 檔案
# --------------------------------------------
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
#
# resource "random_pet" "test" {
#   length = 2
# }
# output "test_result" {
#   value = "Hello from Terraform! Random pet name: ${random_pet.test.id}"
# } 
EOF

cat > "${PROJECT_NAME}/variables.tf" <<EOF
variable "project_id" {
  description = "GCP project ID"
  type        = string
  default     = "${GCP_PROJECT_ID}"
}

variable "region" {
  description = "部署區域"
  type        = string
  default     = "${REGION}"
}
EOF

cat > "${PROJECT_NAME}/outputs.tf" <<EOF
# output "cloud_run_url" {
#   value = module.cicd_app.cloud_run_url
# }
EOF

echo "  → Terraform 檔案產生完成"

# --------------------------------------------
# 步驟 6: 建立 Plan Trigger
# --------------------------------------------
echo ""
echo "[6/7] 建立 Cloud Build Plan Trigger..."

if gcloud builds triggers describe "${PROJECT_NAME}-plan" \
    --region="${REGION}" \
    --project="${GCP_PROJECT_ID}" &>/dev/null; then
  echo "  → Trigger ${PROJECT_NAME}-plan 已存在,略過建立"
else
  gcloud builds triggers create github \
    --name="${PROJECT_NAME}-plan" \
    --region="${REGION}" \
    --project="${GCP_PROJECT_ID}" \
    --repository="${REPOSITORY_ID}" \
    --pull-request-pattern="^main$" \
    --comment-control="COMMENTS_ENABLED" \
    --build-config="cloudbuild-plan.yaml" \
    --service-account="projects/${GCP_PROJECT_ID}/serviceAccounts/${SA_EMAIL}" \
    --included-files="${PROJECT_NAME}/**" \
    --substitutions="_TF_DIR=${PROJECT_NAME}"
  echo "  → Plan trigger 建立完成"
fi

# --------------------------------------------
# 步驟 7: 建立 Apply Trigger
# --------------------------------------------
echo ""
echo "[7/7] 建立 Cloud Build Apply Trigger..."

if gcloud builds triggers describe "${PROJECT_NAME}-apply" \
    --region="${REGION}" \
    --project="${GCP_PROJECT_ID}" &>/dev/null; then
  echo "  → Trigger ${PROJECT_NAME}-apply 已存在,略過建立"
else
  gcloud builds triggers create github \
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
  echo "  → Apply trigger 建立完成(需人工核准才會執行 apply)"
fi

# --------------------------------------------
# 完成
# --------------------------------------------
echo ""
echo "=========================================="
echo "完成! 已建立:"
echo "  ${PROJECT_NAME}/"
echo "  ├── backend.tf"
echo "  ├── provider.tf"
echo "  ├── main.tf"
echo "  ├── variables.tf"
echo "  ├── outputs.tf"
echo "  └── modules/"
echo ""
echo "  Trigger: ${PROJECT_NAME}-plan  (PR 觸發)"
echo "  Trigger: ${PROJECT_NAME}-apply (merge 後觸發,需人工核准)"
echo "=========================================="
echo ""
echo "接下來:"
echo "  1. git add ${PROJECT_NAME}/ && git commit -m 'init ${PROJECT_NAME}'"
echo "  2. git push,開一個 PR 測試 plan trigger 是否正常執行"
echo "  3. merge 後,到 Cloud Build Console 核准 apply trigger"
echo ""