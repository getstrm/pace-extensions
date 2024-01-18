provider "googleworkspace" {
  customer_id  = var.customer_id
}

data "archive_file" "function-source" {
  type        = "zip"
  source_dir  = "bigquery"
  output_path = "function-source.zip"
}

resource "google_service_account" "principal-checker" {
  project      = var.project
  account_id   = "principal-checker"
  display_name = "Principal Checker Service Account"
  description  = "Service Account that is allowed to perform user access checks"
}

resource "google_service_account_key" "principal-checker-key" {
  service_account_id = google_service_account.principal-checker.name
}

resource "google_organization_iam_custom_role" "organization-iam-policy-viewer" {
  org_id      = var.organization_id
  role_id     = "OrganizationIamPolicyViewer"
  title       = "Organization IAM Policy Viewer"
  description = "Created for PACE, permissions needed for BigQuery principal checks."
  permissions = [
    "iam.roles.get", "iam.roles.list", "iam.serviceAccounts.getAccessToken",
    "resourcemanager.projects.get", "resourcemanager.projects.getIamPolicy",
    "resourcemanager.organizations.getIamPolicy"
  ]
}

resource "google_organization_iam_binding" "principal-checker" {
  org_id   = var.organization_id
  for_each = toset([
    "organizations/${var.organization_id}/roles/${google_organization_iam_custom_role.organization-iam-policy-viewer.role_id}",
    "roles/iam.organizationRoleViewer",
    "roles/cloudasset.viewer"
  ])
  role    = each.value
  members = [
    "serviceAccount:${google_service_account.principal-checker.email}",
  ]
}

resource "google_bigquery_connection" "connection" {
  connection_id = "check_principal_access"
  project       = var.project
  location      = var.region
  cloud_resource {}
}

resource "google_project_iam_binding" "run-invoker" {
  project = var.project
  role    = "roles/run.invoker"
  members = [
    "serviceAccount:${google_bigquery_connection.connection.cloud_resource[0].service_account_id}"
  ]
}

resource "google_storage_bucket" "bucket" {
  name                        = "pace-principal-check"
  location                    = var.region
  uniform_bucket_level_access = true
  project                     = var.project
  force_destroy               = true
}

resource "google_storage_bucket_object" "object" {
  name   = "function-source.zip"
  bucket = google_storage_bucket.bucket.name
  source = data.archive_file.function-source.output_path
}

resource "google_cloudfunctions2_function" "check_principal_access" {
  name        = "check_principal_access"
  location    = var.region
  description = "Check if the principal is member of a group or granted a role/permission"
  project     = var.project

  build_config {
    runtime           = "python310"
    entry_point       = "check_principal_access"
    docker_repository = "projects/${var.project}/locations/${var.region}/repositories/gcf-artifacts"

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
      project_id = var.project
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
        location = var.region
      }
    }
  }
  project = var.project
}

resource "google_secret_manager_secret_version" "bigquery_service_account_key_version" {
  secret                = google_secret_manager_secret.bigquery_service_account_key.name
  secret_data           = google_service_account_key.principal-checker-key.private_key
  is_secret_data_base64 = true
}

resource "google_bigquery_dataset" "principal_check_routines" {
  dataset_id = "principal_check_routines"
  project    = var.project
  location   = var.region
  delete_contents_on_destroy = true
}

resource "google_bigquery_job" "job" {
  job_id   = "create_principal_check_routine_${formatdate("YYYYMMDDhhmmss", timestamp())}"
  project  = var.project
  location = var.region

  labels = {
    "example-label" = "create-principal-check-routine"
  }

  query {
    create_disposition = ""
    write_disposition  = ""
    query              = <<EOT
  CREATE or replace FUNCTION `${var.project}`.${google_bigquery_dataset.principal_check_routines.dataset_id}.check_principal_access(x STRING) RETURNS STRING
REMOTE WITH CONNECTION `${var.project}.${var.region}.${google_cloudfunctions2_function.check_principal_access.name}`
OPTIONS (
  endpoint = '${google_cloudfunctions2_function.check_principal_access.url}'
);
EOT
  }
}

data "googleworkspace_privileges" "privileges" {}

locals {
  groups_reader_pace_privileges = [
    for priv in data.googleworkspace_privileges.privileges.items : priv
    if length(regexall("GROUPS_RETRIEVE", priv.privilege_name)) > 0
  ]
}

resource "googleworkspace_role" "groups-reader-pace" {
  name = "Groups Reader Pace"

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
  depends_on = [googleworkspace_role.groups-reader-pace]

  create_duration = "30s"
}

resource "googleworkspace_role_assignment" "principal-checker-groups-admin" {
  depends_on = [time_sleep.wait_30_seconds, google_organization_iam_binding.principal-checker]

  role_id     = googleworkspace_role.groups-reader-pace.id
  assigned_to = google_service_account.principal-checker.unique_id
}
