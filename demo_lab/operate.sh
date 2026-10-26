#!/usr/bin/env bash
set -euo pipefail
connection=$(mktemp)
values=$(mktemp)
trap 'rm -f "$connection" "$values"' EXIT
az storage blob download --account-name "$TFSTATE_STORAGE_ACCOUNT" --container-name "$TFSTATE_CONTAINER" --name "${TFSTATE_KEY}.connection.json" --file "$connection" --auth-mode login --overwrite -o none
test "$(jq -r .state "$connection")" = active
resource_group=$(jq -r .resource_group "$connection")
cluster=$(jq -r .cluster "$connection")
registry=$(jq -r .registry "$connection")
registry_url=$(jq -r .registry_url "$connection")
LAB_GENERATION=$(jq -r .generation "$connection")
export LAB_GENERATION
actual_generation=$(az aks show -g "$resource_group" -n "$cluster" --query tags.LAB_GENERATION -o tsv)
test "$actual_generation" = "$LAB_GENERATION"
az aks get-credentials -g "$resource_group" -n "$cluster" --overwrite-existing
kubelogin convert-kubeconfig -l azurecli

pause() {
  for job in payment-failure-window payment-traffic; do
    kubectl patch cronjob "$job" -n relibank-lab --type merge -p '{"spec":{"suspend":true}}'
  done
  kubectl delete jobs -n relibank-lab -l lab-job=true --ignore-not-found
}
gateway() {
  kubectl run "gateway-control-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}" -n relibank-lab --restart=Never --rm -i \
    --image=curlimages/curl:8.12.1 -- --fail-with-body --max-time 10 -X POST \
    http://mock-gateway:8080/failure-window -H 'Content-Type: application/json' -d "{\"seconds\":$1}"
}

if [[ "$OPERATION" == pause ]]; then pause; gateway 0; exit 0; fi
if [[ "$OPERATION" == resume ]]; then
  for job in payment-failure-window payment-traffic; do
    kubectl patch cronjob "$job" -n relibank-lab --type merge -p '{"spec":{"suspend":false}}'
  done
  exit 0
fi
if [[ "$OPERATION" == trigger ]]; then gateway 600; exit 0; fi

if kubectl get namespace relibank-lab >/dev/null 2>&1; then pause; gateway 0; fi
az acr login --name "$registry"
export IMAGE_COMMIT="$GITHUB_SHA"
if [[ "$OPERATION" == reset ]]; then
  [[ "$BASELINE_IMAGE" == "$registry_url/relibank-payment-lab@sha256:"* ]]
  [[ "${BASELINE_IMAGE##*@sha256:}" =~ ^[a-f0-9]{64}$ ]]
  export LAB_IMAGE="$BASELINE_IMAGE"
  export IMAGE_COMMIT="baseline-${LAB_IMAGE##*@}"
else
  [[ "$OPERATION" == deploy ]]
  tag="$registry_url/relibank-payment-lab:$GITHUB_SHA"
  if ! az acr repository show --name "$registry" --image "relibank-payment-lab:$GITHUB_SHA" -o none 2>/dev/null; then
    docker build --label "org.opencontainers.image.revision=$GITHUB_SHA" -f demo_lab/Dockerfile -t "$tag" .
    docker push "$tag"
  fi
  digest=$(az acr repository show --name "$registry" --image "relibank-payment-lab:$GITHUB_SHA" --query digest -o tsv)
  export LAB_IMAGE="$registry_url/relibank-payment-lab@$digest"
  az acr repository update --name "$registry" --image "${LAB_IMAGE#"$registry_url/"}" --write-enabled false --delete-enabled false -o none
fi

kubectl create namespace relibank-lab --dry-run=client -o yaml | kubectl apply -f -
export MONITORING_ENABLED="${MONITORING_ENABLED:-false}"
if [[ "$MONITORING_ENABLED" == true ]]; then
  : "${NEW_RELIC_LICENSE_KEY:?Configure a new LAB_NR_LICENSE_KEY before opting in to monitoring}"
  kubectl create secret generic newrelic-license -n relibank-lab --from-literal=license-key="$NEW_RELIC_LICENSE_KEY" --dry-run=client -o yaml | kubectl apply -f -
fi
# shellcheck disable=SC2016 # envsubst, not the shell, expands this variable list.
envsubst '${LAB_IMAGE} ${LAB_GENERATION} ${IMAGE_COMMIT} ${MONITORING_ENABLED}' < demo_lab/k8s.yaml > "$values"
kubectl apply -f "$values"
kubectl rollout status deployment/mock-gateway -n relibank-lab --timeout=180s
kubectl rollout status deployment/payment-api -n relibank-lab --timeout=180s

kubectl port-forward -n relibank-lab service/payment-api 18080:80 >/tmp/payment-lab-forward.log 2>&1 &
forward_pid=$!
trap 'kill "$forward_pid" 2>/dev/null || true; rm -f "$connection" "$values"' EXIT
curl --retry 20 --retry-connrefused --retry-delay 1 --fail --silent http://127.0.0.1:18080/healthz
gateway 600
status=$(curl --silent --output /dev/null --write-out '%{http_code}' -X POST http://127.0.0.1:18080/lab/payments)
if [[ "$OPERATION" == reset ]]; then expected=504; else expected="$EXPECTED_STATUS"; fi
test "$status" = "$expected"
# shellcheck disable=SC2016 # Backticks are literal Markdown in the step summary.
printf '## ReliBank payment lab\nImage: `%s`\n\nGeneration: `%s`\n\nSlow payment HTTP status: %s\n' "$LAB_IMAGE" "$LAB_GENERATION" "$status" >> "$GITHUB_STEP_SUMMARY"
printf '\nFailures are paused; the current slow window expires in ten minutes.\n' >> "$GITHUB_STEP_SUMMARY"
kubectl wait --namespace relibank-lab --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' service/payment-api --timeout=300s
public_ip=$(kubectl get service payment-api -n relibank-lab -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
printf '\nAPI: http://%s/docs\n\nNew Relic enabled: %s\n' "$public_ip" "$MONITORING_ENABLED" >> "$GITHUB_STEP_SUMMARY"
if [[ "$MONITORING_ENABLED" == true && -n "${NEW_RELIC_USER_API_KEY:-}" && -n "${NEW_RELIC_ENTITY_GUID:-}" ]]; then
  python demo_lab/change_marker.py
fi