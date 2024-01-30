import json
import os

import functions_framework
import googleapiclient.discovery
from google.cloud import resourcemanager_v3, asset_v1
from google.cloud.asset_v1 import IamPolicyAnalysisQuery
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
    dataset = request_json['calls'][0][1]
    view = request_json['calls'][0][2]

    match principal_type:
        case 'group':
            has_access = groups_check(principal, current_user)
        case 'role':
            has_access = roles_permissions_check(principal, current_user, dataset, view, 'roles')
        case 'permission':
            has_access = roles_permissions_check(principal, current_user, dataset, view,
                                                 'permissions')
        case _:
            has_access = groups_check(principal, current_user)

    return json.dumps({"replies": [f"{has_access}"]})


def groups_check(group, current_user):
    scopes = ['https://www.googleapis.com/auth/cloud-identity.groups']

    credentials = service_account.Credentials.from_service_account_info(
        json.loads(os.environ['SERVICE_ACCOUNT_KEY']), scopes=scopes)

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


def roles_permissions_check(role_or_permission, current_user, dataset, view,
                            roles_or_permissions_type="roles"):
    service_account_key = json.loads(os.environ['SERVICE_ACCOUNT_KEY'])
    client = asset_v1.AssetServiceClient().from_service_account_info(service_account_key)

    if roles_or_permissions_type == "roles":
        access_selector = IamPolicyAnalysisQuery.AccessSelector(roles=[role_or_permission])
    elif roles_or_permissions_type == "permissions":
        access_selector = IamPolicyAnalysisQuery.AccessSelector(permissions=[role_or_permission])
    else:
        raise Exception("roles_or_permissions_type must be 'roles' or 'permissions'")

    resource_selector = IamPolicyAnalysisQuery.ResourceSelector(
        full_resource_name=f"//bigquery.googleapis.com/projects/{service_account_key['project_id']}/datasets/{dataset}/tables/{view}")

    query = IamPolicyAnalysisQuery(
        scope=get_organization_id(service_account_key['project_id']),
        access_selector=access_selector,
        resource_selector=resource_selector,
        identity_selector=IamPolicyAnalysisQuery.IdentitySelector(identity=f"user:{current_user}"),
    )

    request = asset_v1.AnalyzeIamPolicyRequest(analysis_query=query)

    response = client.analyze_iam_policy(request=request)
    return len(response.main_analysis.analysis_results) > 0


def get_organization_id(project):
    client = resourcemanager_v3.ProjectsClient().from_service_account_info(
        json.loads(os.environ['SERVICE_ACCOUNT_KEY']))
    request = resourcemanager_v3.GetProjectRequest(name=f"projects/{project}")
    response = client.get_project(request=request)
    return response.parent
