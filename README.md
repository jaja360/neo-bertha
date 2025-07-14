# Neo Bertha Kubernetes Cluster

Welcome to the configuration repository for **Neo Bertha**, a Kubernetes cluster managed with [TrueCharts ClusterTool](https://truecharts.org) and [Flux](https://fluxcd.io).

```text
  _   _                    ____              _   _           _
 | \ | | _____      _____| __ )  ___   ___ | |_(_)_ __   __| |
 |  \| |/ _ \ \ /\ / / _ \  _ \ / _ \ / _ \| __| | '_ \ / _` |
 | |\  |  __/\ V  V /  __/ |_) | (_) | (_) | |_| | | | | (_| |
 |_| \_|\___| \_/\_/ \___|____/ \___/ \___/ \__|_|_| |_|\__,_|
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

1. Install [ClusterTool](https://truecharts.org/). Make sure you have a
   valid `age` key for decrypting secrets.
2. Run:

```bash
clustertool talos bootstrap
clustertool flux bootstrap
```

These commands set up the base Talos nodes and install Flux, which then
pulls the manifests from this repository.

## Secrets management

All sensitive values are encrypted using SOPS as defined in
[`.sops.yaml`](.sops.yaml). You will need the appropriate Age private key
(`age.agekey`) to decrypt and modify secrets.

## Useful commands
A short list of handy commands lives in [commands.md](commands.md) – for example, to reconcile Flux or view cluster resources.
