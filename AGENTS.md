# Fork maintenance guidance

## Branch topology

- `arps/master-v2` is the maintained fork branch.
- Synchronize it from `MaaAssistantArknights/MaaAssistantArknights` branch `master-v2`.
- Branches named `sync/upstream-master-v2-*` are pull-request branches created after an automatic merge conflict.

## Upstream conflict resolution

- Preserve the fork-owned `.github/workflows` tree. Do not replace it with the upstream workflow tree.
- Preserve ARPS capture behavior while incorporating compatible upstream changes.
- Resolve overlapping WPF changes semantically. Do not choose `ours` or `theirs` for an entire file without inspecting both sides.
- On a sync pull request, merge `origin/arps/master-v2` into the current sync branch, resolve the conflicts, and push only to that pull-request branch.
- Do not merge the pull request. Leave the final review and merge to the maintainer.
- Do not use SSH or access unrelated remote servers.

## Verification

- Run `bash -n tools/fork/sync-arps-master-v2.sh tools/fork/resolve-upstream-merge.sh tools/fork/tests/test-sync-arps-master-v2.sh`.
- Run `bash tools/fork/tests/test-sync-arps-master-v2.sh` after changing the upstream synchronization scripts.
- Report Windows-only build or test steps that the current environment cannot run instead of claiming they passed.

## Commits

- Use Conventional Commits with an English type and a Chinese description after the colon.
- Do not add `Co-Authored-By` trailers.
