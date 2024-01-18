import json
import logging
import os

import functions_framework
import googleapiclient.discovery
import requests
from google.cloud import iam_credentials_v1
from google.oauth2 import service_account


@functions_framework.http
def check_principal_access(request):
    request_json = request.get_json(silent=True)
    current_user = request_json['sessionUser']
    try:
        (principal_type, principal) = request_json['calls'][0][0].split(":", 1)
    except:
        principal_type = ''
        principal = request_json['calls'][0][0]

    match principal_type:
        case 'group':
            hasAccess = check_group_principal(principal, current_user)
        case 'role':
            hasAccess = check_roles_or_permissions_principal(principal, current_user, 'roles')
        case 'permission':
            hasAccess = check_roles_or_permissions_principal(principal, current_user, 'permissions')
        case default:
            hasAccess = check_group_principal(principal, current_user)

    return json.dumps({"replies": [f"{hasAccess}"]})


def check_group_principal(group, current_user):
    SCOPES = ['https://www.googleapis.com/auth/cloud-identity.groups']

    credentials = service_account.Credentials.from_service_account_info(
        json.loads(os.environ['SERVICE_ACCOUNT_KEY']), scopes=SCOPES)

    service = googleapiclient.discovery.build('cloudidentity', 'v1', credentials=credentials)
    param = "&groupKey.id=" + group
    try:
        lookup_group_name_request = service.groups().lookup()
        lookup_group_name_request.uri += param
        lookup_group_name_response = lookup_group_name_request.execute()
        group_name = lookup_group_name_response.get("name")
    except Exception as e:
        return json.dumps({"errorMessage": str(e)})
    memberships = service.groups().memberships().list(parent=group_name).execute()['memberships']
    return any([current_user == m['preferredMemberKey']['id'] for m in memberships])


def check_roles_or_permissions_principal(role_or_permission, current_user,
                                         roles_or_permissions_type="roles"):
    service_account = json.loads(os.environ['SERVICE_ACCOUNT_KEY'])
    base_url = "https://cloudasset.googleapis.com:443"
    access_token = generate_access_token_role_principal(service_account['client_email'])
    organization_id = get_organization_id(service_account['project_id'], access_token)
    response = requests.get(
        f"{base_url}/v1/organizations/{organization_id}:analyzeIamPolicy?alt=json&analysisQuery.accessSelector.{roles_or_permissions_type}={role_or_permission}&analysisQuery.identitySelector.identity=user%3A{current_user}",
        headers={"Authorization": f"Bearer {access_token}"})

    try:
        hasAccess = len(response.json()['mainAnalysis']['analysisResults']) > 0
        return hasAccess
    except:
        logging.error(response.json())
        return False


def get_organization_id(project, token):
    return list(
        filter(
            lambda x: (x['resourceId']['type'] == 'organization'),
            requests.post(
                f"https://cloudresourcemanager.googleapis.com/v1/projects/{project}:getAncestry",
                headers={"Authorization": f"Bearer {token}"}).json()['ancestor']
        )
    )[0]['resourceId']['id']


def generate_access_token_role_principal(client_email):
    client = iam_credentials_v1.IAMCredentialsClient().from_service_account_info(
        json.loads(os.environ['SERVICE_ACCOUNT_KEY']))

    request = iam_credentials_v1.GenerateAccessTokenRequest(
        name=f"projects/-/serviceAccounts/{client_email}",
        scope=['https://www.googleapis.com/auth/iam',
               'https://www.googleapis.com/auth/cloud-platform']
    )

    response = client.generate_access_token(request=request)

    return response.access_token
