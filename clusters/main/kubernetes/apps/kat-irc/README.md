# kat-irc deployment

This directory contains only the TrueCharts app-template deployment.
The reusable Go application, English documentation and container build are in
[jaja360/kat-irc](https://github.com/jaja360/kat-irc), under the MIT license.

## Storage and authentication

One 1 GiB PVC is mounted at `/data`, with the same Backblaze/VolSync conventions
as the other custom apps. The bot reads `/data/config.json`. Persona, memory,
recent history and OAuth credentials also live on that PVC. They are not seeded
from Git or copied from Kubernetes Secrets.

Use `openai.auth: "chatgpt"` for OAuth or `"api_key"` with `openai.api_key` in the
private config file for API billing. There are no OpenAI/IRC Secret manifests,
ConfigMap generators, auth overlays or token-seeding init containers.
TrueCharts still generates the resources needed by VolSync for existing B2
backup credentials. No new `clusterenv.yaml` variables are needed.

Both IRC hostname and port are set in `/data/config.json` (`irc.server`,
`irc.port`). There is no dependency on a particular Ergo Service or Flux resource
name. Change the file and restart the Deployment if the IRC server is renamed.
TLS is selected independently in `irc.tls`; internal Kubernetes DNS does not
provide encryption.

## First installation

1. Merge the application's PR and let its workflow publish
   `ghcr.io/jaja360/kat-irc:0.1.0`. Make the GHCR package public for anonymous pulls.
2. Merge this deployment and change `suspend: true` to `false` in `ks.yaml`
   when ready to install. This draft keeps it suspended until the image exists.
3. Wait for the pod to be **Running**. It is expected to remain **0/1 Ready**
   while the PVC is empty. It will not crash-loop for missing setup files.
4. Prepare the application's sample config locally, select the IRC endpoint,
   channels, nickname and authentication mode, then create your own persona and
   memory files. Set `bot.persona_file` to `persona.md`, `bot.memory_file` to
   `memory.md`, and `openai.credentials_file` to `oauth.json`. Relative paths
   resolve beside `/data/config.json`.

Select the pod and copy files, with the config copied last:

```sh
kubectl -n kat-irc get pods
POD=<running-pod-name>
kubectl -n kat-irc cp ./persona.md "$POD:/data/persona.md"
kubectl -n kat-irc cp ./memory.md "$POD:/data/memory.md"
kubectl -n kat-irc cp ./config.json "$POD:/data/config.json"
kubectl -n kat-irc exec "$POD" -- chmod 600 /data/config.json /data/persona.md /data/memory.md
kubectl -n kat-irc exec "$POD" -- kat-irc check -config /data/config.json
```

For OAuth, start this command and leave it running:

```sh
kubectl -n kat-irc exec -it "$POD" -- kat-irc login -credentials /data/oauth.json
```

In another terminal, using the same pod name:

```sh
kubectl -n kat-irc port-forward --address 127.0.0.1 pod/<running-pod-name> 1455:1455
```

Once forwarding is active, open the URL printed by login in your workstation's
browser. The callback reaches the pod through the forward. After success, stop
the forward; the bot detects the credentials within two seconds and connects.
No browser in the pod, ingress, permanent OAuth Service, device code, or restart
is required. Login only binds the pod's loopback interface.

```sh
kubectl -n kat-irc exec "$POD" -- kat-irc models -config /data/config.json
kubectl -n kat-irc logs "$POD" --tail=50
```

Verify that the selected model is available to the account before first use.
For API-key mode, filling `openai.api_key` completes setup without OAuth.

## Updates and readiness

The bot checks for valid initial configuration and credentials every two seconds.
Once it starts, config/persona/memory changes require:

```sh
kubectl -n kat-irc rollout restart deployment/kat-irc-app-template
```

OAuth credentials are reloaded per request, so repeating `login` works without a
restart. An `enabled` field is not needed or supported.

`Recreate` controls **updates**, not the desired replica count. Default
RollingUpdate can start a new pod before stopping the old one even with one
replica on one node. Recreate stops the old revision first, avoiding simultaneous
IRC clients and PVC writers during upgrades, at the cost of brief downtime.

Health probes use `/healthz` for startup/liveness and `/readyz` for IRC readiness.
Helm `disableWait: true` on install/upgrade permits the initial unready setup
state; check pod readiness/logs separately after setup. It does not disable
Kubernetes probes. The ClusterIP service exposes only health checks internally.

## Backup and rollback

The existing `${BACKBLAZE_*}` settings and `${RESTORE_PVCS}` remain unchanged.
VolSync backs up `/data` daily, including config, persona, memory and credentials.
Only one deployment should use an OAuth session; a restored backup can contain
obsolete rotated tokens and require a new `login`.

Rollback an app update by restoring the previous image tag. To stop the bot,
scale the Deployment to zero with reconciliation paused, or revert the app
registration under normal GitOps controls. Merely suspending reconciliation does
not stop a running pod. Confirm PVC retention before pruning the application.
