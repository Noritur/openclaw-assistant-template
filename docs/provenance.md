# provenance audit

audit date: 2026-08-04.

the public template is a clean implementation with a fresh Git history. the
unlicensed `matskevich/openclaw-infra` repository was inspected at commit
`3c5e7ff012f95f075f30cec1f06291ddd6196217`; no license or copying file was
present, so its source files are not included here.

the overlap review compared every same-named reusable file. exact shared lines
were limited to generic shell control words, a Markdown fence, and common
`.gitignore` entries such as `.env` and `*.log`. assistant rules, runtime jobs, host
bridge code, backup logic, digest logic, and setup orchestration are original
implementations in this repository.

the public export excludes private instance configuration, current-state
snapshots, raw conversations, memory data, credentials, deploy keys, and the
source repository's Git history.

## re-publication, 2026-08-07

the public template was re-created with fresh history at v1.1.0.

the first public release carried this instance's server address, Telegram owner
id and tailnet inside `scripts/check-template-generic.sh` — the script whose
purpose was to keep the template generic, and which excluded itself from its own
scan. CI compounded it by running that scan only when no instance config was
present, which is precisely where there is nothing to compare against.

the marker sat in the repository's root commit, so the history could not be
cleaned without rewriting every commit. the repository was made private, then
re-published as a new repository with a single commit. the original is retained,
private, as `openclaw-assistant-template-archive`.

the exposed values are treated as burned: the repository was public for roughly
a day and public event archives are not retractable. re-publication prevents new
exposure; it does not undo the old one.

the export is now produced by `scripts/export-public-template.sh`, which builds
from committed files only, drops instance-specific paths, and refuses to finish
while any value derived from the private instance config remains in the tree.
