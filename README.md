# Pace Extensions

## BigQuery IAM

Includes:

- provisioning for a `google_bigquery_connection` using terraform
- cloud function udf for bigquery to check permissions, with service account key mounted as secret
  from `Secret Manager`

### Instructions
The BigQuery IAM Check requires a super-admin account to apply. First step is to "trust" the Google Auth Library. Go to [admin console](https://admin.google.com/ac/owl/list?tab=configuredApps). Click `Add App` and select based on Client-ID. The corresponding app-id is `764086051850-6qr4p6gpi6hn506pt8ejuq83di341hur.apps.googleusercontent.com`. Complete the wizard to make it a trusted app.

The following APIs need to be enabled:
- [Admin SDK](https://console.cloud.google.com/apis/library/admin.googleapis.com)
- [Cloud Asset](https://console.cloud.google.com/apis/library/cloudasset.googleapis.com)
- [Cloud Functions](https://console.cloud.google.com/apis/library/cloudfunctions.googleapis.com)
- [Cloud Identity](https://console.cloud.google.com/apis/library/cloudidentity.googleapis.com)
- [Cloud Resource Manager](https://console.cloud.google.com/apis/library/cloudresourcemanager.googleapis.com)
- [Secret Manager](https://console.cloud.google.com/apis/library/secretmanager.googleapis.com)

The BigQuery IAM Check makes use of the ADC for Google.
You need to create oauth credentials for a Desktop application in the Google Cloud Console:
 - Go to the [APIs & Services console](https://console.cloud.google.com/apis/credentials), make sure you select the correct project
 - Click on `Create Credentials` and select `OAuth client ID`
 - Select `Desktop application` as the application type
 - Click on `Create` and download the credentials file

In order to create the terraform resources, 
log in locally as the super-admin account with the `--client-id-file` flag set to the oauth credentials file and the `--scopes` flag with the following scopes:
`https://www.googleapis.com/auth/admin.directory.rolemanagement`,
`https://www.googleapis.com/auth/admin.directory.rolemanagement.readonly`
`https://www.googleapis.com/auth/cloud-platform`

for example:
```bash
gcloud auth application-default login \
 --client-id-file=<path/to/credentials/file.json> \
 --scopes=https://www.googleapis.com/auth/admin.directory.rolemanagement,https://www.googleapis.com/auth/admin.directory.rolemanagement.readonly,https://www.googleapis.com/auth/cloud-platform
```

After login set the quota project you want to use:
```bash
gcloud auth application-default set-quota-project <YOUR_PROJECT>
```

Upon executing `terraform apply`, either enter the correct values for
the variables or create an .envrc file with the following content beforehand:
```bash
export TF_VAR_region="<REGION>"
export TF_VAR_project="<PROJECT>"
export TF_VAR_organization_id="<ORGANIZATION_ID>"
export TF_VAR_customer_id="<CUSTOMER_ID>"
```

`CUSTOMER_ID` is the customer-id of the organization in the [Google admin console](https://admin.google.com/ac/accountsettings).
