# restore from zero

## prerequisites

- private infra repository cloned locally
- private memory repository intact on GitHub
- clean ubuntu 24.04 vps reachable by the configured admin SSH key
- Telegram bot token and Gemini API key available for re-entry
- GitHub CLI authenticated locally

## restore

update `SERVER_IP` in `instance/config.env`, and record the new host's public
key in `SERVER_SSH_HOST_KEY` (`ssh-keyscan -t ed25519 <ip>`) so the first
connection is verified rather than trusted blindly. then run:

```bash
./assistantctl restore
```

for an unverified systemd/apt target, use
`./assistantctl restore --allow-unsupported` only after reading
`docs/platforms.md`.

owner-specific integrations live in `scripts/install-optional-*.sh`. restore runs
whatever it finds, each module decides whether it is enabled, and the public
template export excludes them.

the restore flow bootstraps the runtime user, installs exact pinned versions,
creates a write deploy key for the memory repository, restores memory, writes
SecretRefs, configures the one-owner Telegram channel, installs the Gateway,
Docker boundary, host bridge, backup timer, and daily digest.

the command pauses for OpenAI/Codex device OAuth if no usable profile exists.

## cutover from another server

1. run `./assistantctl backup-now` against the old server.
2. verify the reported local and remote SHA match.
3. stop the old Gateway so only one Telegram poller remains.
4. change `SERVER_IP` and `SERVER_SSH_HOST_KEY`, then run `./assistantctl restore`.
5. run `./assistantctl doctor` and test memory recall in Telegram.
6. keep the old server stopped until the new server has passed the smoke tests.
7. revoke the old server's memory deploy key. restore lists every other key on
   the memory repository with its access level and asks; it never revokes on
   its own. keys created outside this installer are listed too, because a key
   missed silently keeps write access to memory forever. a host that no longer
   runs the assistant must not keep write access to it.

persona, notes, digests, and raw history survive through the memory repository.
OAuth state and provider credentials do not and must be recreated or re-entered.
