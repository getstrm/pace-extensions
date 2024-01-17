terraform {
  backend "gcs" {
    bucket = "getstrm-pace"
    prefix = "provisioning/pace-extensions"
  }
  required_providers {
    google = {
      source = "hashicorp/google"
      version = "~> 5.10.0"
    }
    local = {
      source = "hashicorp/local"
      version = "2.4.1"
    }
  }
  required_version = ">= 1.0.1"
}

provider "google" {
  project = "stream-machine-development"
  region = "europe-west4"
  zone = "europe-west4-a"
}

provider "local" {}