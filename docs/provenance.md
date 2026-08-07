# provenance audit

audit date: 2026-08-04.

the public template is a clean implementation with a fresh Git history. the
unlicensed `matskevich/openclaw-infra` repository was inspected at commit
`3c5e7ff012f95f075f30cec1f06291ddd6196217`; no license or copying file was
present, so its source files are not included here.

the overlap review compared every same-named reusable file. exact shared lines
were limited to generic shell control words, a Markdown fence, and common
`.gitignore` entries such as `.env` and `*.log`. prompts, runtime jobs, host
bridge code, backup logic, digest logic, and setup orchestration are original
implementations in this repository.

the public export excludes private instance configuration, current-state
snapshots, raw conversations, memory data, credentials, deploy keys, and the
source repository's Git history.
