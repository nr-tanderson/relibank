# ReliBank payment timeout workshop

## Scope and current status

This is a small, synthetic Python payment exercise inside your ReliBank fork. It is NOT the full ReliBank banking UI and does not modify the original payment routes. It has no Stripe connection, accounts database, real customer data, or money movement. Its public endpoint is a disposable HTTP API, with Swagger at `/docs`; never submit private data to it. The slow mock gateway and its controls are internal services, not public services. Anyone who discovers the API's public IP can call the synthetic payment endpoint. Use an IP allowlist or HTTPS/authenticated ingress before making this anything other than an isolated temporary lab.

Infrastructure lives separately at `/Users/tanderson/Documents/newrelic/nr-azure-demo`. Application code lives at `/Users/tanderson/Documents/newrelic/relibank`. Neither repo deletes the other's files. The lab uses the shared cluster, NOT ReliBank's original blue/green Terraform or Skaffold deployment. The full banking UI, PetClinic, and their end-to-end deployments are separate follow-up work.

No cloud resources are created by editing these files. Local tests prove HTTP behavior and error recording calls, not successful New Relic ingestion. Docker builds and Azure/GitHub workflows still require a real run after configuration.

## One-time account setup (together, before the demo)

1. Bootstrap the state storage and persistent ACR using `scripts/bootstrap-state.sh` in the infrastructure repo. It is a paid Azure operation: review resource names and cost first. Keep the registry/state account after cluster teardown so image digests survive. Set `LAB_ACR_NAME` in the infrastructure repo to the printed registry name.
2. Configure Azure OIDC for BOTH GitHub repos. The identity used by the app workflow must be the same principal as `AZURE_CLIENT_OBJECT_ID` in the infra repo, or it needs equivalent AKS RBAC Cluster Admin and ACR push permissions. Both identities need Storage Blob Data Contributor on the persistent state account. This demo scopes cloud changes to the dedicated lab; do not reuse production credentials.
3. Configure `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` as Actions secrets in both repos. Configure `TFSTATE_STORAGE_ACCOUNT`, `TFSTATE_CONTAINER`, and `TFSTATE_KEY` as identical repository variables in both repos. The infrastructure repo also needs `TFSTATE_RESOURCE_GROUP` and `AZURE_CLIENT_OBJECT_ID`.
4. In GitHub's infrastructure repo, create environment `lab-infrastructure` with a required reviewer and allow only `main`. Protect `main` with PR review. The plan job runs on main using an OIDC branch subject; the apply job needs a federated subject for `repo:nr-tanderson/nr-azure-demo-opentelemetry:environment:lab-infrastructure`. Store plan-job Azure credentials at repository scope, not only environment scope.
5. In the ReliBank repo, create environment `lab-application` with required reviewer and restrict deployments to `main`. Add its OIDC subject `repo:nr-tanderson/relibank:environment:lab-application`. Protect main with PR review and require the `regression` job in Payment lab regression checks. In a solo lab, arrange reviewer/self-approval settings deliberately; you cannot approve your own PR as an independent reviewer.
6. Leave `enable_monitoring` unchecked. No New Relic credential is needed, no telemetry secret is created, and both containers start without the agent wrapper. Existing upstream `NR_LICENSE_KEY` or `NR_USER_API_KEY` secrets are not used by this lab workflow. The image includes the agent for a later opt-in, but monitoring is disabled by default.
7. Later, together, configure a NEW `LAB_NR_LICENSE_KEY` ingest secret and explicitly check `enable_monitoring` on deployment. Do not use a Browser key. After verifying telemetry, optionally configure a new `LAB_NR_USER_API_KEY` and `LAB_PAYMENT_ENTITY_GUID` for change markers. For EU accounts set `NEW_RELIC_GRAPHQL_URL=https://api.eu.newrelic.com/graphql`. No keys should be pasted into chat or source code. Marker setup and live New Relic verification are deferred.
8. Do NOT enable the copied upstream scheduled flows/test suite for this lab. They target multiple upstream environment names. The original image-build job is guarded off for this fork unless `ENABLE_UPSTREAM_AUTOMATION=true`; leave that variable unset. Use only the new payment-lab workflows and their initially suspended Kubernetes CronJobs.

Important: environment names in YAML do not create approval protection by themselves. GitHub account/organization settings determine whether required-reviewer protection is available. Configure and verify these settings before any apply/deploy.

## 1. Build your cluster

In the infra repo's Actions tab, run **Build AKS infrastructure**. Review the Terraform plan in the run summary, then approve `lab-infrastructure`. Apply uses the exact saved plan, not a fresh unreviewed plan. Plans contain configuration/state metadata; the artifact expires after one day. Rerun planning if expired or Terraform rejects a stale plan.

The workflow publishes a non-secret `${TFSTATE_KEY}.connection.json` blob containing current cluster identifiers, generation UUID, registry, and state. The app workflow reads it fresh each time. A shared Azure blob lease prevents deploy/apply/destroy from operating simultaneously across the two repos. The new generation after teardown/rebuild prevents reuse of an old cluster handoff. An operation encountering the lease fails rather than waiting; rerun when the current operation completes.

Do not run the older Astronomy Shop deployment concurrently; it has not been converted to this shared locking protocol. These new workflows cover the payment lab only.

## 2. Deploy the faulty baseline

In your ReliBank fork, Actions -> **ReliBank payment lab - deploy, reset or pause**:

- Branch: `main` containing this workshop baseline.
- Operation: `deploy`.
- Expected status: `504`.
- Approve `lab-application`.

The workflow builds an image tagged with the commit SHA, resolves it to a digest, locks that image against overwrite/delete, and deploys by digest. It verifies health and activates a ten-minute slow response window, expecting a real HTTP 504. It never retries a payment. Save the full `registry/relibank-payment-lab@sha256:...` string from the run summary as your faulty baseline image. Do not call a branch name or `latest` tag an immutable baseline.

The summary lists the payment Service IP; Azure can initially report `<pending>`. After configuring kubectl access, use:

```sh
kubectl get service payment-api -n relibank-lab
```

Open `http://PUBLIC_IP/docs`, choose POST `/lab/payments`, then Try it out -> Execute. During the slow window the baseline returns 504. To repeat after the ten-minute window, run operation `trigger`. You can also call:

```sh
curl -i -X POST http://PUBLIC_IP/lab/payments
```

The public API is separate from the full ReliBank website. Kubernetes control and the gateway failure endpoint are not exposed by the payment Service.

## 3. Investigate together in New Relic

This section is for later. Until monitoring is enabled with your new key, use the public API response, workflow smoke-test result, and `kubectl logs -n relibank-lab deployment/payment-api` to observe the timeout. Nothing should appear in New Relic from this lab yet.

Select the correct New Relic account and open APM **ReliBank Lab - Payments**. Also expect **ReliBank Lab - Mock Gateway** if its instrumentation is ingested. Allow agent harvest/ingest time; do not assume immediate visibility.

- Failed POST transactions should show `httpx.ReadTimeout` and HTTP 504.
- Look for the outgoing HTTP call to the internal gateway. Distributed trace linking depends on supported HTTPX/FastAPI instrumentation and successful ingest; verify this live rather than assuming it from unit tests.
- Inspect `lab.generation`, `lab.synthetic`, and `deployment.commit` on transactions. Use these to separate rebuilds and the baseline from the fixed version.

Example query (actual transaction naming should be confirmed in your account):

```sql
SELECT count(*), percentage(count(*), WHERE error IS true), percentile(duration, 95)
FROM Transaction
WHERE appName = 'ReliBank Lab - Payments'
FACET deployment.commit
SINCE 30 minutes ago
```

To see periodic traffic, explicitly run operation `resume`: traffic runs once per minute; a ten-minute slow window runs every three hours. These Kubernetes CronJobs exist only in this cluster and start suspended. They never change source code. Run `pause` before your repair demonstration: it suspends both jobs, removes their running Jobs, and clears the slow window. During the fix verification we will deliberately trigger the same slow response again; otherwise a 200 would not prove the code fix.

New Relic does not automatically open a GitHub issue in this setup. We will inspect telemetry and create the issue manually; alert-to-issue automation is separate.

## 4. Your first code fix, with guidance

Create a GitHub issue: **Synthetic payments time out before gateway authorization completes**. Include a trace/error link, failing commit, expected behavior, and acceptance criteria. Do not paste keys or customer data.

From your local ReliBank folder:

```sh
cd /Users/tanderson/Documents/newrelic/relibank
git switch -c fix/payment-timeout
python3 -m venv .venv-lab
.venv-lab/bin/pip install -r demo_lab/requirements.txt
.venv-lab/bin/python -m unittest demo_lab.test_payment_lab.FixExercise.test_slow_valid_gateway_succeeds_with_default_budget -v
```

First observe the failing test: a 300 ms successful dependency response cannot finish before the configured 100 ms timeout. The deliberately faulty producer is `bill_pay/payment_lab.py`:

```python
PAYMENT_TIMEOUT_SECONDS = 0.1
```

Your edit is to change the approved response budget to:

```python
PAYMENT_TIMEOUT_SECONDS = 1.0
```

One second is a lab budget, not a blanket production recommendation. Real payment integrations need aligned service deadlines, reconciliation and idempotency rules. Our small synthetic call has a single attempt and no retries; connect/read timeout behavior remains controlled.

Then run:

```sh
.venv-lab/bin/python -m unittest demo_lab.test_payment_lab.FixExercise demo_lab.test_api -v
git add bill_pay/payment_lab.py
git commit -m "Fix synthetic payment gateway timeout budget"
git push -u origin fix/payment-timeout
```

Open a PR linked to the issue (`Fixes #ISSUE_NUMBER`). Review the one-line diff, passing regression check, and rollout plan. Have the configured reviewer approve and merge. The fix is intentionally NOT applied by this workshop setup; you will make it during the demo.

## 5. Redeploy the fix and prove it

Run the manual lab workflow on merged `main`: operation `deploy`, expected status `200`. It runs the slow-response regression, builds the fixed commit, deploys its digest, and makes the same slow request. The result must be 200 even while the slow gateway window is active. The API tests also verify controlled 503 on connection failure and 504 on timeout; upstream errors are not converted to success.

Record the fixed image digest alongside the baseline. With marker credentials configured the run records a New Relic deployment marker; otherwise note the commit and timestamp manually. In New Relic compare NEW requests for the fixed `deployment.commit` under the same latency. Historical baseline errors remain visible and are not deleted. Do not claim recovery merely because errors aged out of a chart or the scenario stopped.

## 6. Repeat without rewriting Git

Run operation `reset` and paste the saved faulty baseline image digest. Reset pauses scheduled jobs, deploys that exact image, activates the ten-minute slow window, and expects 504. Your fixed code stays on main; no hard reset, revert, or force-push is required. The next demo can use a fresh exercise branch or walk through the existing fix PR and redeploy the fixed digest in a follow-up enhancement.

This narrow lab has no persistent database to reseed. For the full ReliBank app, database reset must be a separately confirmed destructive operation, not silently bundled into reset. Image reset must not delete customer/synthetic data.

## 7. Tear down

Run app operation `pause`, then run **Destroy AKS infrastructure** in the infra repo and type `DESTROY-NR-AKS-DEMO`. Review its saved destroy plan and approve it. Under the shared operation lock, teardown marks the handoff paused, suspends CronJobs, removes active lab Jobs, and applies the reviewed destroy plan. It then marks the handoff destroyed. App operations refuse paused/destroyed or generation-mismatched handoffs.

AKS and its demo workloads are deleted. The persistent state account, image registry, local folders, GitHub branches/PRs, and ingested New Relic data remain. The registry and storage remain billable. Deleting them is a separate permanent cleanup decision, never part of a routine reset.

After rebuilding, first run `reset` with the saved baseline digest; a plain `deploy` builds current main (which may now be fixed). Rediscover the new IP from the Service instead of using the previous lab URL.

## Recovery and limitations

- A killed runner may leave the infinite operation lease held. Confirm no infrastructure/app run is active in either repo before an operator breaks `${TFSTATE_KEY}.operation-lock` using Azure's lease-break command. Never break the Terraform state lease as a shortcut.
- A failed destroy leaves the handoff paused. Investigate and retry teardown; do not blindly publish an active handoff.
- First-deploy Azure role assignment propagation can delay AKS/ACR access; inspect permissions and rerun after propagation.
- Setup has not yet configured your cloud secrets, OIDC federation, GitHub reviewers, or run Azure/Docker deployment. Those are explicit guided steps before the live demo.