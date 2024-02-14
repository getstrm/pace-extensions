import json
import os

import functions_framework
import googleapiclient.discovery
import pandas as pd
from google.cloud import bigquery
from google.oauth2 import service_account


@functions_framework.http
def sync_user_groups(request):
    scopes = ['https://www.googleapis.com/auth/cloud-identity.groups']
    sa_key = json.loads(os.environ['SERVICE_ACCOUNT_KEY'])
    credentials = service_account.Credentials.from_service_account_info(sa_key, scopes=scopes)
    service = googleapiclient.discovery.build('cloudidentity', 'v1', credentials=credentials)

    memberships = get_memberships(service)
    client = bigquery.Client().from_service_account_info(sa_key)
    update_user_groups(client, memberships, sa_key)
    return json.dumps({})


def get_memberships(service):
    memberships = []
    for group in service.groups().list(parent=f"customers/{os.environ['CUSTOMER_ID']}").execute()['groups']:
        group_memberships = service.groups().memberships().list(parent=group['name']).execute()
        if 'memberships' in group_memberships:
            for m in group_memberships['memberships']:
                memberships += [{'userEmail': m['preferredMemberKey']['id'],
                                 'userGroup': group['groupKey']['id']}]
    return memberships


def update_user_groups(client, memberships, sa_key):
    job_config = bigquery.LoadJobConfig(
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
        source_format=bigquery.SourceFormat.CSV,
    )
    client.load_table_from_dataframe(
        pd.DataFrame(memberships),
        '.'.join([sa_key['project_id'], os.environ['USER_GROUPS_DATASET'], os.environ['USER_GROUPS_TABLE']]),
        job_config=job_config
    )
