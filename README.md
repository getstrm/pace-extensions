# Pace Extensions

## BigQuery IAM

includes:

- provisioning for a `google_bigquery_connection` using terraform
- cloud function udf for bigquery to check permissions, with service account key mounted as secret
  from `Secret Manager`

optionally:

- all roles and permissions that a service account needs to be able to use this extension
- step-by-step instructions on how to set up the extension