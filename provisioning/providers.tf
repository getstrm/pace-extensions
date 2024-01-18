terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
    google-beta = {
      source = "hashicorp/google-beta"
      version = "~> 5.2.0"
    }
    googleworkspace = {
      source = "hashicorp/googleworkspace"
      version = "0.7.0"
    }
  }
}