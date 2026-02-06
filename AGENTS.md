# Repository Guidelines

## Project Structure & Module Organization
This repository is a GitOps source of truth for the `main` cluster.

- `clusters/main/`: Talos and Kubernetes manifests.
- `clusters/main/kubernetes/`: top-level Flux `Kustomization` that composes domains (`apps`, `arrs`, `auth`, `core`, `system`, etc.).
- `clusters/main/kubernetes/<domain>/<app>/`: app entrypoint (`ks.yaml`) and deployable manifests under `app/`.
- `repositories/`: Flux `GitRepository`, `HelmRepository`, and OCI source definitions.
- `commands.md` and `notes.md`: operational runbooks and bootstrap notes.

## Build, Test, and Development Commands
There is no Makefile; use CLI tools directly.

- Forgetool project: `https://github.com/trueforge-org/forgetool`
- `forgetool cluster init`: initialize required cluster file/folder layout.
- `forgetool cluster genconfig`: generate Talos and cluster config artifacts.
- `forgetool talos bootstrap`: bootstrap Talos control plane.
- `forgetool flux bootstrap`: install Flux controllers and wire GitOps.
- `flux reconcile source git cluster -n flux-system`: force source refresh.
- `flux get kustomizations --watch`: watch reconciliation status.
- `kubectl get all -A`: quick cluster-wide health snapshot.
- `talosctl etcd snapshot db.snapshot`: create etcd backup before risky infra changes.

## Coding Style & Naming Conventions
Use Kubernetes YAML with consistent two-space indentation and lowercase keys.

- Keep app directories and resource names lowercase and hyphenated (example: `static-web-server`, `kube-prometheus-stack`).
- Use the established layout: `ks.yaml` at app root, `app/helm-release.yaml`, `app/namespace.yaml`, `app/kustomization.yaml` when needed.
- Prefer focused, small manifest changes; avoid mixing unrelated apps in one commit.

## Testing Guidelines
CI currently contains a placeholder workflow only; validation is operational.

- Confirm manifests render and apply cleanly in-cluster via Flux.
- After changes, run `flux reconcile source git cluster -n flux-system` then `flux get all -A`.
- Check app-specific events with `kubectl events -n <namespace> --watch`.

## Commit & Pull Request Guidelines
Recent history favors short imperative commits, often Conventional Commit style.

- Preferred format: `chore(flux): update image <name> <old> -> <new>`.
- For manual fixes, keep scope explicit (example: `qbit: fix vpn`).
- PRs should include: purpose, impacted paths (for example `clusters/main/kubernetes/apps/qbittorrent`), rollout/rollback notes, and any secret handling impact.

## Security & Configuration Tips
- Never commit plaintext secrets; use SOPS rules in `.sops.yaml`.
- Keep `age.agekey`, snapshots, and local secret scratch files untracked (see `.gitignore`).
