# Neo Bertha Kubernetes Cluster

Welcome to the configuration repository for **Neo Bertha**, a Kubernetes cluster
managed with [Forgetool](https://github.com/trueforge-org/forgetool) and [Flux](https://fluxcd.io).

```text
     __                   ___           _   _
  /\ \ \___  ___         / __\ ___ _ __| |_| |__   __ _
 /  \/ / _ \/ _ \ _____ /__\/// _ \ '__| __| '_ \ / _` |
/ /\  /  __/ (_) |_____/ \/  \  __/ |  | |_| | | | (_| |
\_\ \/ \___|\___/      \_____/\___|_|   \__|_| |_|\__,_|
```

## Overview

This repository stores the cluster manifests, Helm charts and GitOps
configuration for Neo Bertha. Flux continuously reconciles the manifests
in this repository to keep the cluster state in sync.

Features:

- **GitOps** workflow via Flux
- **TrueCharts** for easy application deployment
- **Encrypted secrets** with [SOPS](https://github.com/getsops/sops) and Age

## Repository layout

```text
clusters/     # main cluster manifests
repositories/ # Flux sources (Git, Helm, OCI)
commands.md   # helpful CLI snippets
notes.md      # bootstrap & operational notes
```

## Bootstrapping

1. Install [Forgetool](https://github.com/trueforge-org/forgetool). Make sure you have a
   valid `age` key for decrypting secrets.
2. Initialize and generate cluster config:

```bash
forgetool cluster init
forgetool cluster genconfig
```

3. Bootstrap Talos and Flux:

```bash
forgetool talos bootstrap
forgetool flux bootstrap
```

These commands set up the base Talos nodes and install Flux, which then
pulls the manifests from this repository.

## Secrets management

All sensitive values are encrypted using SOPS as defined in
[`.sops.yaml`](.sops.yaml). You will need the appropriate Age private key
(`age.agekey`) to decrypt and modify secrets.

## Useful commands
A short list of handy commands lives in [commands.md](commands.md) – for example, to reconcile Flux or view cluster resources.
