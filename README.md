# openclaw assistant template

a reproducible, single-owner personal assistant for a clean ubuntu 24.04 vps.
the template keeps infrastructure, private instance configuration, and durable
assistant memory in separate trust domains.

## repository model

- this template contains reusable code and a generic memory seed
- each owner creates a private infra repository with `Use this template`
- the wizard creates a second private repository for assistant memory
- API keys, bot tokens, OAuth state, SSH private keys, and full OpenClaw config
  never belong in either Git repository

## quick start

1. create a **private** repository from this GitHub template.
2. clone that private repository on your computer.
3. prepare a clean ubuntu 24.04 vps and an SSH key accepted by `root`.
4. authenticate GitHub CLI with repository access.
5. run:

   ```bash
   ./assistantctl setup
   ```

the wizard creates non-secret `instance/config.env`, initializes the private
memory repository, deploys OpenClaw, prompts for Telegram and Gemini credentials,
pauses for OpenAI/Codex device OAuth, and runs live smoke tests.

for a best-effort non-Ubuntu systemd/apt target, use `--allow-unsupported` only
after reading the platform notes:

```bash
./assistantctl setup --allow-unsupported
```

## operations

```bash
./assistantctl restore
./assistantctl doctor
./assistantctl backup-now
```

memory is exported and pushed by a persistent systemd timer every five minutes.
the five-minute recovery target applies while the VPS can reach GitHub; it is
not a claim of absolute zero-loss storage.

a failed backup alerts the owner over Telegram, and a separate watchdog timer
reports a backup that has stopped happening quietly, which a failed-unit alert
cannot catch.

## security boundary

- normal shell and filesystem tools run in a networkless Docker sandbox
- the agent workspace is the only writable filesystem exposed to ordinary tools
- generic elevated execution is disabled
- read-only host diagnostics use fixed parameterless `assistant_host_*` tools
- Gateway restart requires a one-time owner approval
- executable runtime code is root-owned under `/opt/openclaw-assistant`
- the writable memory repository contains data and persona files only
- the sandbox boundary is verified by attempting to cross it, not by reading
  the configuration back
- automatic backup scans staged blobs for secrets and fails before commit/push
- persona files are digest-checked against a root-owned baseline, so the agent
  cannot make a change to its own stated rules durable without owner approval

## portability

ubuntu 24.04 is the only supported full-stack target. see
[platform notes](docs/platforms.md) before attempting Debian, another systemd
distribution, macOS, or Windows.

the live migration and all runtime checks have passed on ubuntu 24.04. a fully
clean restore still requires a disposable VPS acceptance run before this build
is described as clean-slate verified.

## versioning

runtime versions are exact in `template.lock`. bootstrap fails if the pinned
OpenClaw package cannot be installed; it never falls back to `latest`.

## license and provenance

MIT licensed. this repository uses fresh history and does not copy source files
from the unlicensed `matskevich/openclaw-infra` repository. see the recorded
[provenance audit](docs/provenance.md).
