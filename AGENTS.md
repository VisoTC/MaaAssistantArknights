# Fork maintenance guidance

## Branch topology

- `arps/master-v2` always contains exactly one ARPS overlay commit on top of an official stable upstream tag.
- The overlay commit records its base in the `ARPS-Upstream-Tag` and `ARPS-Upstream-Commit` trailers.
- Branches named `sync/upstream-tag-v*` are temporary conflict handoff branches.
- A fork tag such as `v6.12.2` points to the rebuilt ARPS commit, while the same tag under `refs/upstream-tags/` points to the official upstream commit.

## Upstream tag synchronization

- Synchronize stable tags matching `vMAJOR.MINOR.PATCH`; do not synchronize alpha or beta tags.
- Reapply the current single ARPS overlay commit to the new official tag. Do not merge `master-v2`.
- Preserve ARPS capture behavior, fork-owned workflows, `AGENTS.md`, and `tools/fork`.
- Resolve overlapping WPF changes semantically. Do not choose an entire file from one side without inspecting both versions.
- A conflict handoff branch starts at the official upstream tag and contains a committed conflict snapshot. Resolve every marker, create a new commit, and push only to that branch.
- Do not merge the handoff pull request. The next sync run validates the branch, squashes it back to one overlay commit, updates `arps/master-v2`, creates the same-name fork tag, and closes the pull request.
- Do not use SSH or access unrelated remote servers.

## Verification

- Run `bash -n tools/fork/sync-arps-release-tag.sh tools/fork/tests/test-sync-arps-release-tag.sh`.
- Run `bash tools/fork/tests/test-sync-arps-release-tag.sh` after changing the synchronization scripts.
- Report Windows-only build or test steps that the current environment cannot run instead of claiming they passed.

## Commits

- Use Conventional Commits with an English type and a Chinese description after the colon.
- Do not add `Co-Authored-By` trailers.
