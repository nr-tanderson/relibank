# ReliBank full-app support lab

This separate, manually operated workflow deploys the ReliBank dashboard and APIs into the shared single-node AKS lab. It uses demo data and generated database passwords. Only the small NGINX edge service is public; app APIs, PostgreSQL, MSSQL, Kafka, and Zookeeper remain internal. New Relic and Chaos Mesh are not installed, and no scenario is scheduled.

## Deploy and verify

Run **ReliBank full app lab** with `deploy`. The workflow builds commit-tagged AMD64 images, creates database credentials inside the cluster, deploys the UI/API stack, waits for database initialization and app rollouts, tags supported managed resources, and reports the UI URL. Use only the demo accounts supplied by the app's seed data. Do not enter real payment or personal information.

## Short incident drills

Run **ReliBank full app SRE scenarios** manually, one operation at a time:

- `status`: capture pods, services, deployments, statefulsets, and recent events.
- `api-outage` / `api-recover`: scale one API to zero, reproduce the error in the UI, inspect endpoints/events/logs, then restore one replica.
- `image-pull-failure` / `image-rollback`: point one API at a deliberately missing ACR tag, diagnose `ErrImagePull` or `ImagePullBackOff`, then roll back to its last good ReplicaSet.
- `database-outage` / `database-recover`: stop PostgreSQL or MSSQL, observe dependent failures and recovery, then restore the database. Its PVC is retained.

For each drill, record customer impact, timestamps, affected endpoint, relevant `kubectl describe`, logs and events, root cause, mitigation, and a concise customer update. Do not run these scenarios against any environment except this isolated lab.

## Remove the app

Run **ReliBank full app lab** with `uninstall` and type `UNINSTALL-RELIBANK-LAB`. This deletes the namespace, demo records, services, and public IP but leaves AKS running. Destroy the cluster separately when finished to stop node compute charges; the Terraform state and ACR remain billable.