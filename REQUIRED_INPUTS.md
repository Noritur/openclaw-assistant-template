# required inputs

the setup wizard asks for these non-secret values:

- assistant id, display name, and owner display name
- ubuntu vps address, root SSH access, runtime user, and local SSH key filename
- numeric Telegram owner id
- private infra and memory repository names
- explicit raw conversation consent
- optional GitHub MCP and Taildrive choices
- Tailnet suffix, source device, and share name when Taildrive is enabled
- server and source device already enrolled in the same Tailscale network when
  Taildrive is enabled

the wizard prompts privately for:

- Telegram bot token
- Gemini API key for memory embeddings and daily digest
- optional existing Gateway token; otherwise one is generated

OpenAI/Codex subscription OAuth, Tailscale enrollment, Google API restrictions,
and optional GitHub fine-grained token entry remain interactive. the setup flow
prompts for that token after installing the read-only MCP module. none of these
credentials are recoverable from GitHub.
