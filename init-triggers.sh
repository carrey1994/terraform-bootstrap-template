#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Terraform Project Bootstrap Script (互動式版本)
#
# 用法:
#   ./init-triggers.sh
#   直接執行後,依照畫面提示逐項輸入即可,不需要再帶命令列參數。
#   有預設值的欄位(例如 region、service account)若直接按 Enter,
#   會自動採用預設值,並在畫面上提示「使用預設值」。
#
# 功能(依實際執行順序):
#   0. 互動式收集所有參數(project name / gcp project id / github owner
#      / github repo / region / service account / 專案語言)
#   1. 檢查/建立 GitHub 2nd-gen Connection(需要人工完成 OAuth 授權)
#   2. 檢查/註冊 Repository
#   3. 建立 GCS bucket 作為 terraform state backend
#   4. 建立 / 檢查 Cloud Build 執行用的 Service Account,並授予所需權限
#   5. 建立 Cloud Build Plan Trigger(PR 觸發)
#   6. 建立 Cloud Build Apply Trigger(merge 後觸發,需人工核准)
#   7. 建立本地資料夾結構(放在最後,避免中途失敗留下半成品資料夾)
#      → 若專案語言為 terraform,會額外產生 backend.tf / provider.tf /
#        main.tf / variables.tf / outputs.tf 等檔案
#      → 若不是 terraform,只會建立空資料夾,並提示使用者將程式碼
#        放進該資料夾
#
# 設計理念:
#   所有「遠端 GCP 資源」的檢查/建立步驟都排在前面,且都具備冪等性(已存在則略過)。
#   本地資料夾與檔案的建立放在最後一步 —— 只有前面所有步驟都成功,
#   本地端才會出現任何檔案,避免中途失敗後留下半成品資料夾,導致重跑時卡在
#   「資料夾已存在」的檢查而必須手動清理。
#
# 執行此腳本所需的權限(你自己登入的 gcloud 帳號需要具備):
#   roles/iam.serviceAccountAdmin        (建立新的 Service Account)
#   roles/resourcemanager.projectIamAdmin (修改 project IAM policy)
#   roles/cloudbuild.builds.editor        (建立 trigger)
#   roles/storage.admin                   (建立 GCS bucket)
# ============================================

# --------------------------------------------
# 共用的互動輸入函式
# --------------------------------------------

# prompt_required <提示文字> <變數名稱>
# 必填欄位,沒有預設值,空白會一直重新詢問
prompt_required() {
  local prompt_msg="$1"
  local var_name="$2"
  local input=""
  while [ -z "${input}" ]; do
    read -r -p "${prompt_msg}: " input
    if [ -z "${input}" ]; then
      echo "  ⚠ 此欄位為必填,請重新輸入"
    fi
  done
  printf -v "${var_name}" '%s' "${input}"
}

# prompt_with_default <提示文字> <預設值> <變數名稱>
# 有預設值的欄位,直接按 Enter 就會採用預設值
prompt_with_default() {
  local prompt_msg="$1"
  local default_val="$2"
  local var_name="$3"
  local input=""
  read -r -p "${prompt_msg} [預設: ${default_val}]: " input
  if [ -z "${input}" ]; then
    echo "  → 未輸入,使用預設值: ${default_val}"
    printf -v "${var_name}" '%s' "${default_val}"
  else
    printf -v "${var_name}" '%s' "${input}"
  fi
}

# --------------------------------------------
# 0. 互動式收集參數
# --------------------------------------------
echo "=========================================="
echo "Terraform Project Bootstrap - 參數設定"
echo "=========================================="
echo ""

prompt_required "專案名稱 (project_name)" PROJECT_NAME
prompt_required "GCP Project ID" GCP_PROJECT_ID
prompt_required "GitHub Owner (org 或帳號)" GITHUB_OWNER
prompt_required "GitHub Repo 名稱" GITHUB_REPO

echo ""
prompt_with_default "部署區域 (region)" "asia-east1" REGION

# SA_EMAIL 的預設值依賴 GCP_PROJECT_ID,所以要在拿到 GCP_PROJECT_ID 之後才組出來
DEFAULT_SA_EMAIL="cloud-build-sa-tester@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
prompt_with_default "Cloud Build Service Account email" "${DEFAULT_SA_EMAIL}" SA_EMAIL

echo ""
prompt_with_default "專案語言 (terraform / 其他,例如 nodejs、python...)" "terraform" PROJECT_LANGUAGE

# 統一轉小寫方便比對
PROJECT_LANGUAGE_LOWER=$(echo "${PROJECT_LANGUAGE}" | tr '[:upper:]' '[:lower:]')

# 防呆:確認所有必要變數都不是空字串
for var_name in PROJECT_NAME GCP_PROJECT_ID GITHUB_OWNER GITHUB_REPO REGION SA_EMAIL PROJECT_LANGUAGE; do
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
SA_ACCOUNT_ID="${SA_EMAIL%%@*}"

echo ""
echo "=========================================="
echo "Terraform Project Bootstrap - 確認參數"
echo "  Project Name      : ${PROJECT_NAME}"
echo "  GCP Project ID    : ${GCP_PROJECT_ID}"
echo "  GitHub Repo       : ${GITHUB_OWNER}/${GITHUB_REPO}"
echo "  Region            : ${REGION}"
echo "  Service Account   : ${SA_EMAIL}"
echo "  State Bucket      : ${BUCKET_NAME}"
echo "  Connection Name   : ${CONNECTION_NAME}"
echo "  專案語言           : ${PROJECT_LANGUAGE}"
echo "=========================================="

# --------------------------------------------
# 前置檢查(只做檢查,不建立任何東西)
# --------------------------------------------
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

# 提早檢查資料夾是否已存在(只檢查,不建立)
# 避免流程跑到最後一步才發現資料夾衝突,浪費前面所有步驟的時間
if [ -d "${PROJECT_NAME}" ]; then
  echo "錯誤: 資料夾 ${PROJECT_NAME} 已經存在,請確認後手動處理"
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
# 步驟 3: 建立 GCS bucket
# --------------------------------------------
echo ""
echo "[3/7] 檢查 / 建立 GCS bucket: ${BUCKET_NAME}..."

if gsutil ls -b "gs://${BUCKET_NAME}" &>/dev/null; then
  echo "  → Bucket 已存在,略過建立"
else
  gsutil mb -p "${GCP_PROJECT_ID}" -l "${REGION}" "gs://${BUCKET_NAME}"
  gsutil versioning set on "gs://${BUCKET_NAME}"
  echo "  → Bucket 建立完成,已啟用版本控制"
fi

# --------------------------------------------
# 步驟 4: 建立 / 檢查 Cloud Build 執行用的 Service Account
# --------------------------------------------
echo ""
echo "[4/7] 檢查 / 建立 Service Account: ${SA_EMAIL}..."

if gcloud iam service-accounts describe "${SA_EMAIL}" \
    --project="${GCP_PROJECT_ID}" &>/dev/null; then
  echo "  → Service Account 已存在,略過建立"
else
  gcloud iam service-accounts create "${SA_ACCOUNT_ID}" \
    --project="${GCP_PROJECT_ID}" \
    --display-name="Cloud Build - ${PROJECT_NAME}"
  echo "  → Service Account 建立完成"

  # 新建立的 SA,IAM 系統需要幾秒鐘傳播,避免緊接著的角色授予失敗
  echo "  等待 Service Account 生效..."
  sleep 10
fi

echo ""
echo "  授予 Service Account 所需權限..."

INFRA_ROLES=(
  "roles/run.admin"
  "roles/artifactregistry.admin"
  "roles/iam.serviceAccountUser"
  "roles/compute.networkAdmin"
  "roles/compute.securityAdmin"
  "roles/compute.loadBalancerAdmin"
  "roles/cloudbuild.builds.editor"
  "roles/logging.logWriter"
  "roles/storage.admin"
)

for role in "${INFRA_ROLES[@]}"; do
  echo "    → ${role}"
  gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${role}" \
    --condition=None \
    --quiet &>/dev/null
done

echo "  → 權限授予完成"

# --------------------------------------------
# 步驟 5: 建立 Plan Trigger
# --------------------------------------------
echo ""
echo "[5/7] 建立 Cloud Build Plan Trigger..."

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
# 步驟 6: 建立 Apply Trigger
# --------------------------------------------
echo ""
echo "[6/7] 建立 Cloud Build Apply Trigger..."

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
# 步驟 7: 建立本地資料夾結構(放在最後)
#   - 專案語言為 terraform → 產生完整 tf 檔案
#   - 專案語言不是 terraform → 只建立空資料夾,並提示使用者
# --------------------------------------------
echo ""
echo "[7/7] 建立本地資料夾結構..."

# 再次確認資料夾不存在(防止前面步驟執行期間,資料夾被其他程序意外建立)
if [ -d "${PROJECT_NAME}" ]; then
  echo "錯誤: 資料夾 ${PROJECT_NAME} 已經存在,無法建立"
  echo "(所有 GCP 端資源已建立完成,只差本地檔案,請手動處理資料夾衝突後,"
  echo " 重新執行本腳本即可 —— 前面步驟都具備冪等性,會自動略過已存在的資源)"
  exit 1
fi

if [ "${PROJECT_LANGUAGE_LOWER}" = "terraform" ]; then
  mkdir -p "${PROJECT_NAME}/modules"

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

  cat > "${PROJECT_NAME}/main.tf" <<'EOF'
variable "length" {
  description = "A test length input variable"
  type        = string
  default     = 5
}

module "random" {
  source = "git::ssh://git@github.com/carrey1994/terraform-modules.git//random?ref=main"
  length = var.length
}

output "random_string" {
  value = module.random.result
}
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

  echo "  → 資料夾與 Terraform 檔案建立完成"
else
  mkdir -p "${PROJECT_NAME}"
  echo "  → 已建立空資料夾 ${PROJECT_NAME}/(專案語言為 \"${PROJECT_LANGUAGE}\",非 terraform)"
  echo ""
  echo "  ⚠ 警告: 未產生任何 Terraform 檔案(backend.tf / provider.tf / main.tf...)"
  echo "  ⚠ 請將你的 ${PROJECT_LANGUAGE} 專案原始碼與相關檔案,自行放入下列資料夾:"
  echo "      ./${PROJECT_NAME}/"
  echo "  ⚠ 注意: Cloud Build trigger 的 included-files 已設定為 \"${PROJECT_NAME}/**\","
  echo "     若你的檔案未放在此資料夾內,plan / apply trigger 將不會被觸發。"
fi

# --------------------------------------------
# 完成
# --------------------------------------------
echo ""
echo "=========================================="
echo "完成! 已建立:"
echo "  ${PROJECT_NAME}/"
if [ "${PROJECT_LANGUAGE_LOWER}" = "terraform" ]; then
  echo "  ├── backend.tf"
  echo "  ├── provider.tf"
  echo "  ├── main.tf"
  echo "  ├── variables.tf"
  echo "  ├── outputs.tf"
  echo "  └── modules/"
else
  echo "  (空資料夾,請自行放入 ${PROJECT_LANGUAGE} 專案檔案)"
fi
echo ""
echo "  Service Account: ${SA_EMAIL}"
echo "  Trigger: ${PROJECT_NAME}-plan  (PR 觸發)"
echo "  Trigger: ${PROJECT_NAME}-apply (merge 後觸發,需人工核准)"
echo "=========================================="
echo ""
echo "接下來:"
echo "  1. git add ${PROJECT_NAME}/ && git commit -m 'init ${PROJECT_NAME}'"
echo "  2. git push,開一個 PR 測試 plan trigger 是否正常執行"
echo "  3. merge 後,到 Cloud Build Console 核准 apply trigger"
echo ""