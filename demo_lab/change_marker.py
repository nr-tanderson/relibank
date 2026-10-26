import json
import os
import urllib.request


mutation = """mutation($deployment: ChangeTrackingDeploymentInput!) {
  changeTrackingCreateDeployment(deployment: $deployment) { deploymentId }
}"""
payload = {
    "query": mutation,
    "variables": {
        "deployment": {
            "entityGuid": os.environ["NEW_RELIC_ENTITY_GUID"],
            "version": os.environ["LAB_IMAGE"],
            "commit": os.environ["GITHUB_SHA"],
            "description": f"Synthetic payment lab {os.environ['OPERATION']}",
        }
    },
}
request = urllib.request.Request(
    os.getenv("NEW_RELIC_GRAPHQL_URL") or "https://api.newrelic.com/graphql",
    data=json.dumps(payload).encode(),
    headers={"API-Key": os.environ["NEW_RELIC_USER_API_KEY"], "Content-Type": "application/json"},
)
with urllib.request.urlopen(request, timeout=20) as response:
    result = json.load(response)
if result.get("errors"):
    raise RuntimeError("New Relic rejected the change marker; inspect account/key/entity configuration")
print("New Relic deployment marker recorded")