# kat-irc deployment (draft)

This directory contains only the TrueCharts deployment configuration.
The application source and image build will live in a separate public kat-irc repository.

Private persona and memory files must be supplied directly on the persistent volume:

- `/data/persona.md`
- `/data/memory.md`

They are not included in Git or in a ConfigMap. The existing VolSync configuration backs up `/data`.
IRC connectivity remains configurable through `KAT_IRC_HOST` and `KAT_IRC_PORT`.

Deployment is suspended. Authentication setup is being simplified before activation.
