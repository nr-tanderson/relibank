#!/usr/bin/env bash
set -euo pipefail

: "${TFSTATE_STORAGE_ACCOUNT:?}"
: "${TFSTATE_CONTAINER:?}"
: "${TFSTATE_KEY:?}"
: "${AZURE_SUBSCRIPTION_ID:?}"
: "${REGISTRY_NAME:?}"
: "${IMAGE_TAG:?}"

connection=$(mktemp)
manifest=$(mktemp)
trap 'rm -f "$connection" "$manifest"' EXIT

az storage blob download \
  --account-name "$TFSTATE_STORAGE_ACCOUNT" \
  --container-name "$TFSTATE_CONTAINER" \
  --name "${TFSTATE_KEY}.connection.json" \
  --file "$connection" \
  --auth-mode login \
  --overwrite \
  --output none

test "$(jq -r .state "$connection")" = active
resource_group=$(jq -r .resource_group "$connection")
cluster=$(jq -r .cluster "$connection")
generation=$(jq -r .generation "$connection")
actual_generation=$(az aks show --resource-group "$resource_group" --name "$cluster" --query tags.LAB_GENERATION -o tsv)
test "$generation" = "$actual_generation"

az aks get-credentials --resource-group "$resource_group" --name "$cluster" --overwrite-existing
kubelogin convert-kubeconfig -l azurecli

if [[ "$OPERATION" == uninstall ]]; then
  test "$CONFIRMATION" = UNINSTALL-RELIBANK-LAB
  kubectl delete namespace relibank --ignore-not-found --wait=true --timeout=10m
  printf 'ReliBank namespace and demo data deleted. AKS remains running.\n' >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

test "$OPERATION" = deploy
registry_url=$(az acr show --name "$REGISTRY_NAME" --query loginServer -o tsv)
az acr login --name "$REGISTRY_NAME"

build_image() {
  local name="$1" context="$2" dockerfile="$3"
  local image="$registry_url/$name:$IMAGE_TAG"
  if az acr repository show --name "$REGISTRY_NAME" --image "$name:$IMAGE_TAG" --output none 2>/dev/null; then
    printf 'Using existing immutable commit image %s\n' "$image"
    return
  fi
  docker buildx build \
    --platform linux/amd64 \
    --label "org.opencontainers.image.revision=$GITHUB_SHA" \
    --tag "$image" \
    --push \
    --file "$dockerfile" \
    "$context"
}

build_image frontend-service frontend_service frontend_service/Dockerfile
build_image accounts-service . accounts_service/Dockerfile
build_image auth-service . auth_service/Dockerfile
build_image transaction-service . transaction_service/Dockerfile
build_image bill-pay-service . bill_pay/Dockerfile
build_image notifications-service notifications_service notifications_service/Dockerfile
build_image scheduler-service scheduler_service scheduler_service/Dockerfile
build_image support-service . support_service/Dockerfile
build_image risk-assessment-service . risk_assessment_service/Dockerfile
build_image postgres-custom accounts_service/postgres accounts_service/postgres/Dockerfile
build_image mssql-custom transaction_service/mssql transaction_service/mssql/Dockerfile
build_image kafka-with-monitoring kafka_service kafka_service/Dockerfile

kubectl create namespace relibank --dry-run=client -o yaml | kubectl apply -f -
if ! kubectl get secret database-credentials -n relibank >/dev/null 2>&1; then
  mssql_password="N#$(openssl rand -hex 24)Aa9!"
  postgres_password="P#$(openssl rand -hex 24)Bb9!"
  kubectl create secret generic database-credentials -n relibank \
    --from-literal=MSSQL_SA_PASSWORD="$mssql_password" \
    --from-literal=MSSQL_SA_USER=SA \
    --from-literal=POSTGRES_USER=postgres \
    --from-literal=POSTGRES_PASSWORD="$postgres_password" \
    --dry-run=client -o yaml | kubectl apply -f -
  unset mssql_password postgres_password
fi

kubectl kustomize k8s/overlays/lab --load-restrictor LoadRestrictionsNone > "$manifest"
REGISTRY_URL="$registry_url" IMAGE_TAG="$IMAGE_TAG" ruby demo_lab/render-full-app.rb "$manifest"

kubectl apply -f "$manifest"
for workload in deployment/accounts-db statefulset/mssql deployment/zookeeper deployment/kafka; do
  kubectl rollout status "$workload" -n relibank --timeout=15m
done

for job in postgres-init mssql-init; do
  kubectl wait --for=condition=complete "job/$job" -n relibank --timeout=20m
done

for workload in deployment/accounts-service deployment/auth-service deployment/bill-pay-service deployment/frontend-service deployment/notifications-service deployment/risk-assessment-service deployment/scheduler-service deployment/support-service deployment/transaction-service deployment/relibank-edge; do
  kubectl rollout status "$workload" -n relibank --timeout=10m
done

node_group=$(az aks show --resource-group "$resource_group" --name "$cluster" --query nodeResourceGroup -o tsv)
node_group_id=$(az group show --name "$node_group" --query id -o tsv)
tags=(OWNER=TANDERSON PROJECT=nr-azure-demo-opentelemetry MANAGED_BY=Terraform)
az tag update --resource-id "$node_group_id" --operation Merge --tags "${tags[@]}" -o none
resources_json=$(az resource list --resource-group "$node_group" -o json)
while IFS= read -r resource_id; do
  az tag update --resource-id "$resource_id" --operation Merge --tags "${tags[@]}" -o none
done < <(jq -r '.[] | select((.type | ascii_downcase) as $type | ["microsoft.compute/virtualmachinescalesets", "microsoft.compute/disks", "microsoft.managedidentity/userassignedidentities", "microsoft.network/virtualnetworks", "microsoft.network/networksecuritygroups", "microsoft.network/publicipaddresses", "microsoft.network/loadbalancers", "microsoft.network/networkinterfaces"] | index($type)) | .id' <<< "$resources_json")

kubectl wait --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' service/relibank-edge -n relibank --timeout=5m
public_ip=$(kubectl get service relibank-edge -n relibank -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl --retry 30 --retry-connrefused --retry-delay 2 --fail --silent "http://$public_ip/" >/dev/null
{
  printf '## ReliBank full app\n\n'
  printf 'UI and same-origin API gateway: http://%s/\n\n' "$public_ip"
  printf 'Image commit: %s\n\nCluster generation: %s\n\n' "$IMAGE_TAG" "$generation"
  printf 'Only the tagged edge gateway is public. SQL Server, PostgreSQL, Kafka, and app APIs are internal. New Relic and scheduled chaos are disabled.\n'
} >> "$GITHUB_STEP_SUMMARY"