# GitHub read-only MCP

this optional module installs the official GitHub MCP server at the version
and sha256 digest recorded in `template.lock`. the digest is committed under
review, so a release replaced after that commit fails to install; a checksum
file fetched alongside the artifact would only prove the download was intact.
the wrapper runs with `--read-only` and enables only repositories, issues,
pull requests, and Actions tools.

the binary and both wrappers are installed root-owned, outside the runtime
user's home, because the wrapper reads the token out of the secrets file.

create a fine-grained token at:

https://github.com/settings/personal-access-tokens/new

grant access only to repositories the assistant may inspect and select these
read-only permissions:

- contents
- issues
- pull requests
- actions

`assistantctl setup` and `assistantctl restore` prompt for this token after the
module is installed. to rotate it later, connect to the configured runtime user
and execute:

```bash
/usr/local/libexec/set-openclaw-github-token
```

the token is written to `$HOME/.openclaw/secrets.json`, never to the workspace.
verify with:

```bash
openclaw mcp doctor github --probe
```

a private repository returning `404` usually means it was not selected in the
fine-grained token's repository access.
