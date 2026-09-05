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

- clustertool project: `https://github.com/trueforge-org/clustertool`
- `clustertool init`: initialize required cluster file/folder layout.
- `clustertool genconfig`: generate Talos and cluster config artifacts, SOPS-encrypt `clusterenv.yaml`, and regenerate the derived secret files (see "Secrets & Config Generation Workflow" below).
- `clustertool talos bootstrap`: bootstrap Talos control plane.
- `clustertool flux bootstrap`: install Flux controllers and wire GitOps.
- `flux reconcile source git cluster -n flux-system`: force source refresh.
- `flux get kustomizations --watch`: watch reconciliation status.
- `kubectl get all -A`: quick cluster-wide health snapshot.
- `talosctl etcd snapshot db.snapshot`: create etcd backup before risky infra changes.

## Secrets & Config Generation Workflow
`clusters/main/clusterenv.yaml` is the single source of truth for all cluster settings, secrets, and `${VAR}` substitution values. **The user edits it exclusively — the AI must never read, decrypt, or modify it**, nor the generated secret files (`clustersettings.secret.yaml`, `deploykey.secret.yaml`, `talsecret.yaml`).

- User workflow: edit `clusterenv.yaml`, then run `clustertool cluster genconfig`, which SOPS-encrypts it and regenerates the derived files — notably `clusters/main/kubernetes/flux-system/flux/clustersettings.secret.yaml` (the `cluster-config` ConfigMap Flux uses for `postBuild.substituteFrom`), plus `deploykey.secret.yaml` and `talsecret.yaml`.
- When a change requires new or updated secret/setting values, the AI tells the user exactly which keys to add or change in `clusterenv.yaml`; the user applies them and runs `genconfig`. The AI never touches those files itself (no `sops -d`, no `sops --set`, no edits).
- The AI may freely edit non-secret manifests. App manifests reference these values with unquoted `${VAR}` placeholders (e.g. `enabled: ${RESTORE_PVCS}`). Booleans are stored as strings in clusterenv (`RESTORE_PVCS: "false"`) and render as proper YAML booleans after Flux substitution.

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
