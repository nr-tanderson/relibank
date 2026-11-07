#!/usr/bin/env bash
set -euo pipefail

: "${TFSTATE_STORAGE_ACCOUNT:?}"
: "${TFSTATE_CONTAINER:?}"
: "${TFSTATE_KEY:?}"

connection=$(mktemp)
trap 'rm -f "$connection"' EXIT
az storage blob download --account-name "$TFSTATE_STORAGE_ACCOUNT" --container-name "$TFSTATE_CONTAINER" --name "${TFSTATE_KEY}.connection.json" --file "$connection" --auth-mode login --overwrite --output none
test "$(jq -r .state "$connection")" = active
resource_group=$(jq -r .resource_group "$connection")
cluster=$(jq -r .cluster "$connection")
generation=$(jq -r .generation "$connection")
test "$(az aks show --resource-group "$resource_group" --name "$cluster" --query tags.LAB_GENERATION -o tsv)" = "$generation"
az aks get-credentials --resource-group "$resource_group" --name "$cluster" --overwrite-existing
kubelogin convert-kubeconfig -l azurecli
kubectl get namespace relibank >/dev/null

api_targets=(accounts-service auth-service bill-pay-service transaction-service)
database_targets=(accounts-db mssql)
case "$OPERATION" in
  status)
    kubectl get pods,services,deployments,statefulsets -n relibank -o wide | tee -a "$GITHUB_STEP_SUMMARY"
    kubectl get events -n relibank --sort-by=.lastTimestamp | tail -n 30 >> "$GITHUB_STEP_SUMMARY"
    ;;
  api-outage|api-recover)
    [[ " ${api_targets[*]} " == *" $TARGET "* ]]
    replicas=1
    [[ "$OPERATION" == api-outage ]] && replicas=0
    kubectl scale "deployment/$TARGET" -n relibank --replicas="$replicas"
    if [[ "$OPERATION" == api-recover ]]; then
      kubectl rollout status "deployment/$TARGET" -n relibank --timeout=5m
    fi
    ;;
  image-pull-failure|image-rollback)
    [[ " ${api_targets[*]} " == *" $TARGET "* ]]
    if [[ "$OPERATION" == image-pull-failure ]]; then
      registry_url=$(jq -r .registry_url "$connection")
      current_image=$(kubectl get deployment "$TARGET" -n relibank -o jsonpath='{.spec.template.spec.containers[0].image}')
      kubectl set image "deployment/$TARGET" "$TARGET=$registry_url/$TARGET:training-not-found-$GITHUB_RUN_ID" -n relibank
      printf 'Changed %s from %s to an intentionally missing ACR tag.\n' "$TARGET" "$current_image" >> "$GITHUB_STEP_SUMMARY"
    else
      kubectl rollout undo "deployment/$TARGET" -n relibank
      kubectl rollout status "deployment/$TARGET" -n relibank --timeout=5m
    fi
    ;;
  database-outage|database-recover)
    [[ " ${database_targets[*]} " == *" $TARGET "* ]]
    workload=deployment/accounts-db
    [[ "$TARGET" == mssql ]] && workload=statefulset/mssql
    replicas=1
    [[ "$OPERATION" == database-outage ]] && replicas=0
    kubectl scale "$workload" -n relibank --replicas="$replicas"
    if [[ "$OPERATION" == database-recover ]]; then
      kubectl rollout status "$workload" -n relibank --timeout=10m
    fi
    ;;
  *)
    echo "Unsupported operation: $OPERATION" >&2
    exit 2
    ;;
esac

{
  printf '\nOperation: %s\nTarget: %s\nCluster generation: %s\n\n' "$OPERATION" "$TARGET" "$generation"
  printf 'Use the ReliBank UI, kubectl events, describe, logs, probes, and rollout status to investigate. Recovery operations restore one replica or roll back the image. Database PVCs are retained.\n'
} >> "$GITHUB_STEP_SUMMARY"