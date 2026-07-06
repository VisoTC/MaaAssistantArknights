#!/usr/bin/env bash
set -euo pipefail

conflicts="$(git diff --name-only --diff-filter=U || true)"
if [[ -z "$conflicts" ]]; then
    exit 0
fi

while IFS= read -r path; do
    case "$path" in
        .github/workflows/*)
            git checkout --ours -- "$path"
            git add -- "$path"
            ;;
        .claude/skills/changelog/SKILL.md|CHANGELOG.md|resource/*|tools/OptimizeTemplates/optimize_templates.json)
            git checkout --theirs -- "$path"
            git add -- "$path"
            ;;
        3rdparty/EmulatorExtras|src/MAAUnified|src/MaaMacGui|src/MaaUtils|src/maa-cli|test)
            git checkout --theirs -- "$path"
            git add -- "$path"
            ;;
    esac
done <<< "$conflicts"

remaining="$(git diff --name-only --diff-filter=U || true)"
if [[ -n "$remaining" ]]; then
    echo "Unresolved conflicts remain:"
    echo "$remaining"
    exit 1
fi
