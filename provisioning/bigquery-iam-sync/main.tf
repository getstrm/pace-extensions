provider "googleworkspace" {
  customer_id = var.customer_id
}

data "googleworkspace_privileges" "privileges" {}

locals {
  groups_reader_pace_privileges = [
    for priv in data.googleworkspace_privileges.privileges.items : priv
    if length(regexall("GROUPS_RETRIEVE", priv.privilege_name)) > 0
  ]
}

resource "google_service_account" "principal_sync" {
  project      = var.project
  account_id   = "principal-sync"
  display_name = "Principal Sync Service Account"
  description  = "Service Account that is allowed to list groups and update the user groups table in BigQuery."
}

resource "google_service_account_key" "principal_sync_key" {
  service_account_id = google_service_account.principal_sync.name
}

resource "google_project_iam_member" "principal_sync" {
  project  = var.project
  for_each = toset([
    "roles/bigquery.dataEditor",
    "roles/cloudscheduler.admin",
    "roles/cloudfunctions.invoker",
    "roles/bigquery.jobUser"
  ])
  role   = each.value
  member = "serviceAccount:${google_service_account.principal_sync.email}"
}

resource "google_bigquery_dataset" "user_groups" {
  dataset_id                 = "user_groups"
  project                    = var.project
  location                   = var.region
  delete_contents_on_destroy = true
}

resource "google_bigquery_table" "user_groups" {
  dataset_id = google_bigquery_dataset.user_groups.dataset_id
  table_id   = "user_groups"
  project    = var.project

  schema = <<EOF
[
  {
    "name": "userEmail",
    "type": "STRING",
    "mode": "REQUIRED"
  },
  {
    "name": "userGroup",
    "type": "STRING",
    "mode": "REQUIRED"
  }
]
EOF
}

resource "google_bigquery_table" "user_groups_view" {
  dataset_id = google_bigquery_dataset.user_groups.dataset_id
  table_id   = "user_groups_view"
  project    = var.project
  view {
    query          = "select userEmail, userGroup from `${var.project}.${google_bigquery_dataset.user_groups.dataset_id}.${google_bigquery_table.user_groups.table_id}` where userEmail = SESSION_USER()"
    use_legacy_sql = false
  }
}

resource "google_bigquery_dataset_access" "view_authorization" {
  dataset_id = google_bigquery_dataset.user_groups.dataset_id
  project    = var.project
  view {
    project_id = google_bigquery_table.user_groups_view.project
    dataset_id = google_bigquery_dataset.user_groups.dataset_id
    table_id   = google_bigquery_table.user_groups_view.table_id
  }
}

resource "google_bigquery_table_iam_binding" "binding" {
  project    = google_bigquery_table.user_groups_view.project
  dataset_id = google_bigquery_table.user_groups_view.dataset_id
  table_id   = google_bigquery_table.user_groups_view.table_id
  role       = "roles/bigquery.dataViewer"
  members    = [
    "allAuthenticatedUsers",
  ]
}

resource "googleworkspace_role" "groups_reader_pace_sync" {
  name = "Groups Reader Pace Sync"

  dynamic "privileges" {
    for_each = local.groups_reader_pace_privileges
    content {
      service_id     = privileges.value["service_id"]
      privilege_name = privileges.value["privilege_name"]
    }
  }
}

// this is needed as google admin api needs a little time to propagate the id
resource "time_sleep" "wait_30_seconds" {
  depends_on = [googleworkspace_role.groups_reader_pace_sync]

  create_duration = "30s"
}

resource "googleworkspace_role_assignment" "principal_sync_groups_admin" {
  depends_on = [time_sleep.wait_30_seconds, google_project_iam_member.principal_sync]

  role_id     = googleworkspace_role.groups_reader_pace_sync.id
  assigned_to = google_service_account.principal_sync.unique_id
}

resource "google_secret_manager_secret" "bigquery_service_account_sync_key" {
  secret_id = "pace-bigquery-service-account-sync-key"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
  project = var.project
}

resource "google_secret_manager_secret_version" "bigquery_service_account_key_version" {
  secret                = google_secret_manager_secret.bigquery_service_account_sync_key.name
  secret_data           = google_service_account_key.principal_sync_key.private_key
  is_secret_data_base64 = true
}

resource "google_secret_manager_secret" "customer_id_secret_key" {
  secret_id = "customer-id-key"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
  project = var.project
}

resource "google_secret_manager_secret_version" "customer_id_secret_key_version" {
  secret      = google_secret_manager_secret.customer_id_secret_key.name
  secret_data = var.customer_id
}


# Cloud function
data "archive_file" "function_source" {
  type        = "zip"
  source_dir  = "cloud-function-source"
  output_path = "function-source.zip"
}

resource "google_storage_bucket" "bucket" {
  name                        = "pace-principal-sync"
  location                    = var.region
  uniform_bucket_level_access = true
  project                     = var.project
  force_destroy               = true
}

resource "google_storage_bucket_object" "function_source" {
  name   = "function-source.zip"
  bucket = google_storage_bucket.bucket.name
  source = data.archive_file.function_source.output_path
}

resource "google_cloudfunctions2_function" "sync_user_groups" {
  name        = "sync-user-groups"
  location    = var.region
  description = "Sync user groups table in bigquery"
  project     = var.project

  # added label to force recreation of the function when the source code changes
  labels = {
    "function_source" = data.archive_file.function_source.id
  }

  build_config {
    runtime     = "python310"
    entry_point = "sync_user_groups"

    source {
      storage_source {
        bucket = google_storage_bucket.bucket.name
        object = google_storage_bucket_object.function_source.name
      }
    }
  }
  lifecycle {
    ignore_changes = [
      build_config[0].docker_repository
    ]
  }
  service_config {
    available_memory   = "256M"
    timeout_seconds    = 60
    max_instance_count = 100
    ingress_settings   = "ALLOW_INTERNAL_ONLY"
    secret_environment_variables {
      key        = "SERVICE_ACCOUNT_KEY"
      project_id = var.project
      secret     = google_secret_manager_secret.bigquery_service_account_sync_key.secret_id
      version    = "latest"
    }
    secret_environment_variables {
      key        = "CUSTOMER_ID"
      project_id = var.project
      secret     = google_secret_manager_secret.customer_id_secret_key.secret_id
      version    = "latest"
    }
    environment_variables = {
      USER_GROUPS_DATASET = google_bigquery_dataset.user_groups.dataset_id
      USER_GROUPS_TABLE   = google_bigquery_table.user_groups.table_id
    }
  }
}

resource "google_cloud_run_service_iam_binding" "binding" {
  location = google_cloudfunctions2_function.sync_user_groups.location
  project  = google_cloudfunctions2_function.sync_user_groups.project
  service  = google_cloudfunctions2_function.sync_user_groups.name
  role     = "roles/run.invoker"
  members  = [
    "serviceAccount:${google_service_account.principal_sync.email}",
  ]
}

resource "google_cloud_scheduler_job" "sync_user_groups" {
  name        = "sync_user_groups"
  description = "Sync user groups table in bigquery"
  project     = var.project
  region      = var.scheduler_region
  schedule    = var.cron_schedule

  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "POST"
    uri         = google_cloudfunctions2_function.sync_user_groups.url
    oidc_token {
      service_account_email = google_service_account.principal_sync.email
    }
  }
}