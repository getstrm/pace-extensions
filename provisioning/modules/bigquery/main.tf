locals {
  region = "europe-west4"
  project = "stream-machine-development"
}

resource "google_bigquery_connection" "connection" {
  connection_id = "check_principal_access"
  project       = local.project
  location      = local.region
  cloud_resource {}
}

resource "google_project_iam_binding" "run-invoker" {
  depends_on = [google_bigquery_connection.connection]
  project    = local.project
  role       = "roles/run.invoker"
  members    = [
    "serviceAccount:${google_bigquery_connection.connection.cloud_resource[0].service_account_id}"
  ]
}

resource "google_storage_bucket" "bucket" {
  name                        = "pace-principal-check"
  location                    = "EU"
  uniform_bucket_level_access = true
  project                     = local.project
}

resource "google_storage_bucket_object" "object" {
  name   = "function-source.zip"
  bucket = google_storage_bucket.bucket.name
  source = "function-source.zip"
}

resource "google_cloudfunctions2_function" "check_principal_access" {
  name        = "check_principal_access"
  location    = local.region
  description = "Check if the principal is member of a group or granted a role/permission"
  project     = local.project

  build_config {
    runtime     = "python310"
    entry_point = "check_principal_access"
    source {
      storage_source {
        bucket = google_storage_bucket.bucket.name
        object = google_storage_bucket_object.object.name
      }
    }
  }

  service_config {
    available_memory   = "256M"
    timeout_seconds    = 60
    max_instance_count = 100
    secret_environment_variables {
      key        = "SERVICE_ACCOUNT_KEY"
      project_id = local.project
      secret     = google_secret_manager_secret.bigquery_service_account_key.secret_id
      version    = "latest"
    }
  }
}

resource "google_secret_manager_secret" "bigquery_service_account_key" {
  secret_id = "pace-bigquery-service-account-key"
  replication {
    user_managed {
      replicas {
        location = local.region
      }
    }
  }
  project = local.project
}

resource "google_secret_manager_secret_version" "bigquery_service_account_key_version" {
  secret = google_secret_manager_secret.bigquery_service_account_key.name
  secret_data = file("sa-key.json")
}
