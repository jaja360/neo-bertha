# (Re)bootstrapping a cluster

- `clustertool talos bootstrap`
- `clustertool flux bootstrap`

# Claiming a Plex server

- [Get the claim token](https://account.plex.tv/fr/claim)
- `curl -X POST 'http://127.0.0.1:32400/myplex/claim?token=CLAIM_TOKEN_HERE'`
