# platform support

## supported target

ubuntu 24.04 on a dedicated VPS with:

- systemd user services and `loginctl enable-linger`
- root SSH access
- Docker Engine
- Node 24
- outbound access to npm, GitHub, Telegram, OpenAI, and Gemini

the runtime migration and smoke tests pass on this target. a second disposable
VPS is still required to verify the complete clean-slate `setup` and `restore`
flows independently.

## Debian and other systemd Linux

these are best-effort, not verified. run setup or restore with
`--allow-unsupported` only after confirming:

- `apt-get`, `systemctl`, `loginctl`, `runuser`, `flock`, and Docker are present
- the runtime user has a persistent systemd user manager
- package names used by the ubuntu scripts exist on the target distribution
- AppArmor or SELinux permits Docker and the Gateway service

the installer deliberately stops on an unknown platform unless that flag is
explicit. passing it removes the version gate, not the security checks.

## macOS and Windows

upstream OpenClaw supports these operating systems, but this template's complete
stack does not. the Docker sandbox lifecycle, root-owned host bridge, systemd
timers, Taildrive job, and restore tests are Linux-specific. use a small ubuntu
VPS or VM for equivalent behavior.
