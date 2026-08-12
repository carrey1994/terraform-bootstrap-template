# Terraform + Cloud Build CI/CD Bootstrap Template

這是一份 Terraform 專案的啟動範本（Template Repository），用來快速建立「Terraform + Cloud Build」的 CI/CD 流程：PR 觸發 `plan`、merge 後觸發 `apply`（需人工核准）。

---

## 這份 Template 幫你做什麼

跑一次 `init.sh`，會自動完成：

1. 檢查 / 建立 GitHub 2nd-gen Connection（首次使用需要一次性手動授權）
2. 檢查 / 註冊 Repository 到 Cloud Build
3. 建立 Terraform 專案資料夾（`backend.tf`、`provider.tf`、`main.tf`、`variables.tf`、`outputs.tf`）
4. 建立 GCS bucket 作為 Terraform state backend
5. 建立 Cloud Build **Plan Trigger**（PR 觸發）
6. 建立 Cloud Build **Apply Trigger**（merge 後觸發，需人工核准）

---

## 開始使用：三步驟

### 步驟 1：建立你自己的專案 repo

**不要直接 fork 這個 repo。** 請用 GitHub 的 **"Use this template"** 功能：

1. 打開這個 template repo 首頁
2. 點右上角綠色按鈕 **"Use this template" → "Create a new repository"**
3. 幫新 repo 命名（例如 `my-project-infra`），選擇 public 或 private
4. 建立完成後，會得到一個**全新、獨立**的 repo，跟這個 template 沒有任何 git 關聯

> 為什麼不用 fork？Fork 出來的 repo 在 Git 層面仍與原 repo 關聯，Cloud Build 2nd-gen 對 fork 出去的 PR 有更嚴格的觸發限制。用 template 建立的新 repo 是完全獨立、乾淨的複製，Cloud Build 會把它當成一個普通的新 repo 處理。

### 步驟 2：Clone 並執行 init.sh

```bash
git clone https://github.com/<your-org>/<your-new-repo>.git
cd <your-new-repo>

chmod +x init.sh
./init.sh <project_name> <gcp_project_id> <github_owner> <github_repo> [region] [sa_email]
```

**參數說明：**

| 參數 | 說明 | 範例 |
|---|---|---|
| `project_name` | Terraform 資料夾名稱，同時也是 GCS state 的 prefix 跟 trigger 命名前綴 | `atlas-p6` |
| `gcp_project_id` | 實際的 GCP project ID | `my-gcp-project-id` |
| `github_owner` | GitHub org 或帳號名稱 | `my-org` |
| `github_repo` | 步驟 1 建立的新 repo 名稱 | `my-project-infra` |
| `region`（選填） | 部署區域，預設 `asia-east1` | `asia-east1` |
| `sa_email`（選填） | Cloud Build 執行用的 Service Account，預設 `cloud-build-sa-tester@<gcp_project_id>.iam.gserviceaccount.com` | — |

**範例：**

```bash
./init.sh atlas-p6 my-gcp-project-id my-org my-project-infra asia-east1
```

#### 首次使用會需要一次手動授權

如果這個 GitHub org/帳號還沒連接過 Cloud Build，script 執行到一半會停下來，印出類似訊息：

```
⚠ 尚未完成 GitHub App 授權(目前狀態: PENDING_INSTALL_APP)

請前往以下網址完成授權:
https://console.cloud.google.com/cloud-build/repositories/2nd-gen?project=<gcp_project_id>

步驟:
  1. 找到 connection: <github_owner>-connection
  2. 完成 GitHub App 安裝/授權流程
  3. 確認授權存取 <github_owner> 這個 org/帳號下的 repository
```

**請照著指示，在瀏覽器裡完成 GitHub App 的登入與安裝授權**（一路點到底，中途不要重新整理或關閉分頁）。完成後，script 會自動偵測到狀態變成 `COMPLETE` 並繼續往下執行，不需要手動重跑。

> 同一個 GitHub org/帳號只需要授權一次。之後在同個 org 底下建立的其他專案，會直接沿用這個 connection，不會再要求重新授權。

### 步驟 3：把產生的檔案 commit 上去

```bash
git add <project_name>/
git commit -m "init <project_name>"
git push
```

推上去後，去開一個 Pull Request（merge 目標設為 `main`），確認 Plan Trigger 有正常執行：

```bash
gcloud builds list \
  --project=<gcp_project_id> \
  --region=<region> \
  --limit=5 \
  --format="table(id,status,createTime)"
```

PR 通過 review 後 merge 到 `main`，Apply Trigger 會被觸發，但**需要人工核准**才會真的執行 `terraform apply`：

```
Cloud Build Console → Triggers → 找到待核准的 build → Approve
```

---

## 產生出來的專案結構

```
<project_name>/
├── backend.tf       # 指向 GCS bucket:<gcp_project_id>-tf-state,prefix = <project_name>
├── provider.tf       # google provider 設定
├── main.tf           # 主要資源定義(預設是空殼,附註解範例)
├── variables.tf       # project_id、region 變數(已帶入預設值)
├── outputs.tf         # 輸出值(預設是空殼)
└── modules/           # 放這個專案專屬的 module(如果有共用 module,建議放在 repo 根目錄的 modules/,用相對路徑引用)
```

---

## CI/CD 運作流程

```
開發者 push 到 PR 分支
      │
      ▼
Plan Trigger 觸發(監聽 pull_request 事件)
      │  跑 cloudbuild-plan.yaml
      │  → terraform fmt -check
      │  → terraform init
      │  → terraform validate
      │  → terraform plan
      ▼
PR 通過 review,merge 到 main
      │
      ▼
Apply Trigger 觸發(監聽 push to main 事件)
      │  跑 cloudbuild-apply.yaml
      │  → terraform init
      │  → terraform validate
      │  → terraform apply(需人工核准才會真正執行)
      ▼
Infra 部署完成
```

兩個 trigger 都用 `included_files` 限定只監聽對應 `<project_name>/**` 路徑下的變動，同一個 repo 底下可以容納多個獨立的 Terraform 專案資料夾，互不干擾。

---

## 常見問題

### Q: PR 送出後,Plan Trigger 完全沒有反應？

檢查幾個可能原因：

1. **`cloudbuild-plan.yaml` 內容是否為空** — 這個檔案在 repo 根目錄，必須包含實際的 build steps，不能是空檔案
2. **PR 改動的檔案是否落在 `<project_name>/**` 路徑下** — `included_files` 只會比對這個路徑，改到其他地方(例如只改 README)不會觸發
3. **Connection 狀態是否為 `COMPLETE`**：
   ```bash
   gcloud builds connections describe <github_owner>-connection \
     --region=<region> --project=<gcp_project_id> \
     --format="value(installationState.stage)"
   ```
4. **PR 是否來自 fork** — 來自 fork 的 PR 有更嚴格的觸發限制，可能需要有寫入權限的人在 PR 底下留言 `/gcbrun` 才會觸發

### Q: 需要在 PR 留言 `/gcbrun` 嗎？

取決於 trigger 的 `comment-control` 設定：
- `COMMENTS_DISABLED`：不需要，開 PR 自動觸發
- `COMMENTS_ENABLED`：同 repo 分支通常自動觸發；來自 fork 的 PR 需要有寫入權限的人留言 `/gcbrun`（必須是整則留言唯一內容，不能有其他文字）

### Q: Apply Trigger 一直卡在 `Required 'compute.xxx.get'` 或類似 403 錯誤？

代表執行 apply 的 Service Account（預設 `cloud-build-sa-tester@<gcp_project_id>.iam.gserviceaccount.com`）權限不足。這個 SA 需要視你的 Terraform 內容補齊對應角色，常見組合：

```
roles/run.admin
roles/artifactregistry.admin
roles/iam.serviceAccountAdmin
roles/iam.serviceAccountUser
roles/compute.networkAdmin
roles/compute.securityAdmin
roles/compute.loadBalancerAdmin
roles/cloudbuild.builds.editor
roles/resourcemanager.projectIamAdmin
```

建議把這份清單寫進 Terraform（例如放進 `bootstrap` 專案）統一管理，避免每次卡在不同的權限缺口才手動補一次。

### Q: 重新執行 `init.sh` 會不會重複建立資源？

不會。腳本在每個步驟都會先檢查資源是否已存在（`describe` 先行），已存在的會自動略過，可以安全地重複執行。

---

## 清理測試資源

如果只是測試用途，測完記得清理：

```bash
cd <project_name>
terraform destroy
```

若要移除 Cloud Build trigger：

```bash
gcloud builds triggers delete <project_name>-plan --region=<region> --project=<gcp_project_id>
gcloud builds triggers delete <project_name>-apply --region=<region> --project=<gcp_project_id>
```