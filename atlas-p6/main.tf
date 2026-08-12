# atlas-p6 主要資源定義
#
# main.tf
resource "random_pet" "test" {
  length = 2
}

output "test_result" {
  value = "Hello from Terraform! Random pet name: ${random_pet.test.id}"
}