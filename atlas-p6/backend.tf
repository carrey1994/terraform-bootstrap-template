terraform {
  backend "gcs" {
    bucket = "aic-james-playgroud-tf-state"
    prefix = "atlas-p6"
  }
}
