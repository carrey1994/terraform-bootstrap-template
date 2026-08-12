1. 使用者 clone 這個 template repo
2. 執行 init.sh,傳入新專案資訊
3. Script 檢查 GitHub connection 是否存在
   ├─ 存在 → 直接繼續
   └─ 不存在 → 印出說明,引導去 Console 手動連接,等使用者按 Enter 確認完成後繼續
4. Script 檢查這個 repo 有沒有被註冊進 Cloud Build(google_cloudbuildv2_repository)
   ├─ 存在 → 略過
   └─ 不存在 → 用 gcloud 建立這個 repository 註冊
5. 建立資料夾、backend.tf 等 Terraform 檔案
6. 建立 GCS bucket
7. 建立 plan/apply trigger