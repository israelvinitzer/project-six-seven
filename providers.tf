terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

provider "google" {
  project = "red-truck-454019-n6"
  region  = "me-west1"
}