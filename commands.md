# Some useful commands

## Talos

- Open a CLI: `kubectl debug -n kube-system -it --image alpine node/k8s-control-1`
- Open Dashboard: `talosctl dashboard`
- Create an etcd backup: `talosctl etcd snapshot db.snapshot`

## Flux

- Reconcile: `flux reconcile source git cluster -n flux-system`
- Show kustomizations: `flux get kustomizations --watch`
- Show everything: `flux get all -A`

## Kubernetes

- Show all resources: `kubectl get all -A`
- Show events for an app: `kubectl events -n [name] --watch`
- Redirect port: `kubectl port-forward -n [namespace] service/[service_name] [local_port]:[pod_port]`
- Get a secret: `kubectl get secret -n namespace secret-name -o jsonpath="{.data.token}" | base64 -d`

## Longhorn

- Report engine-image migration status: `scripts/longhorn-engine-migrate.sh --mode report`
- Migrate one eligible detached V1 volume and wait for convergence: `scripts/longhorn-engine-migrate.sh --mode detached --limit 1`
- Migrate one eligible attached V1 volume during a low-traffic window: `scripts/longhorn-engine-migrate.sh --mode attached --limit 1`
- Before manual migration, confirm automatic engine upgrades are disabled: `kubectl -n longhorn-system get settings.longhorn.io concurrent-automatic-engine-upgrade-per-node-limit -o jsonpath='{.value}{"\n"}'` (must be `0`)
- Repeat each command until the report has no V1 volumes on the old image. Do not delete the old EngineImage manually: Longhorn removes a non-default, unreferenced EngineImage after about 60 minutes.
