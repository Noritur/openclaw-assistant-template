# secret refs

the runtime secret file is `$HOME/.openclaw/secrets.json`, mode `0600`.

supported keys:

- `TELEGRAM_BOT_TOKEN`
- `GEMINI_API_KEY`
- `GATEWAY_AUTH_TOKEN`
- optional `GITHUB_MCP_PAT`

OpenClaw config stores file references to these keys, not plaintext values.
the file, local `.env`, OAuth database, and SSH private keys must never be
committed or copied into the assistant workspace.
