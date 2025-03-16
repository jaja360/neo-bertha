# Some useful commands

## Talos

- Open a CLI: kubectl debug -n kube-system -it --image alpine node/k8s-control-1
- Open Dashboard: talosctl dashboard
- Create an etcd backup: talosctl etcd snapshot db.snapshot

## Flux

- Reconcile: flux reconcile source git cluster -n flux-system
- Show kustomizations: flux get kustomizations --watch
- Show everything: flux get all -A

## Kubernetes

- Show all resources: kubectl get all -A
- Show events for an app: kubectl events -n [name] --watch
- Redirect port: kubectl port-forward -n [namespace] service/[service_name] [local_port]:[pod_port]
