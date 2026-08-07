# security model

this is a single trusted owner system, not a hostile multi-tenant platform.

## boundaries

- secrets use OpenClaw file SecretRefs outside Git
- ordinary runtime and filesystem tools execute in a networkless Docker sandbox
- filesystem tools are workspace-only
- generic elevated execution is disabled
- root-owned bridge code exposes only fixed parameterless host diagnostics
- Gateway restart is the only mutating bridge tool and requires owner approval
- diagnostic output is bounded and marked as untrusted data
- executable hooks, jobs, and plugins are installed outside writable memory

## memory

raw conversation export is disabled until the owner records explicit consent,
and consent gates the upload as well as the export: with consent withdrawn the
backup refuses `raw/` and `raw-indexed/` even if those files are already on
disk. `assistantctl consent-revoke` untracks them; the recorded history still
contains whatever was pushed earlier.

when enabled, user and assistant text is redacted for common token formats before
being committed to a private repository. tool arguments and tool results are not
exported. private GitHub repositories are not end-to-end encrypted.

semantic memory is a separate path from this consent flag. `memorySearch`
indexes session content and sends embeddings to Gemini whenever it is enabled,
regardless of `RAW_MEMORY_CONSENT`, which governs only what is written to the
memory repository.

automatic commits stage only the documented memory paths. an unexpected staged
path, a secret pattern in any staged blob, or branch divergence stops the backup
before commit or push, and clears the index so the next run re-evaluates rather
than failing forever on a stale entry. every successful push is verified against
the remote branch SHA.

the persona files are model-layer policy living in a workspace the agent can
write. their digests are recorded root-owned beside the runtime code, and a
change that does not match is withheld from the commit while the rest of the
backup proceeds. the owner approves a change with `assistantctl policy-approve`.
this constrains what the agent can make durable; it is not a defence against a
compromised Gateway, which is covered by residual risk below.

a failed backup or digest job alerts the owner over Telegram, and a watchdog
timer reports a backup that has simply stopped happening: lock contention, a
disabled timer, or a host that was off produce no failed unit to alert on.

## verification

the boundary is checked as enforced behaviour, not as configuration readback.
`scripts/test-hybrid-security.sh` inspects the running sandbox container for
network mode, user, privilege, added capabilities, and mounts, then attempts
network egress, a read of the secrets file, and a read of the root-owned
runtime code from inside it. each attempt must fail. the checks were themselves
validated against a deliberately unisolated container to confirm they report a
broken boundary rather than passing by default.

## residual risk

prompt injection remains possible at the model layer. the enforcement boundary
is the sandbox, fixed tool interface, approval hook, and filesystem ownership,
not text instructions. a compromised trusted Gateway process can control Docker;
do not share one Gateway between mutually untrusted users.
