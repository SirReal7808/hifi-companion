#!/bin/bash
# SessionStart hook for Claude Code (wired in .claude/settings.json).
# Prints a one-screen repo status into the session's context. Offline except
# `gh pr list` (capped at 5 s); never fails the session.

cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0

branch=$(git branch --show-current 2>/dev/null)
dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
behind=$(git rev-list --count HEAD..origin/main 2>/dev/null)
version=$(awk -F'"' '/MARKETING_VERSION:/ {m=$2} /CURRENT_PROJECT_VERSION:/ {b=$2} END {if (m) print m " (build " b ")"}' project.yml 2>/dev/null)
tag=$(git describe --tags --abbrev=0 origin/main 2>/dev/null)

echo "HiFi Companion — session status"
echo "  Branch:   ${branch:-detached} (${dirty} uncommitted, ${behind:-?} behind origin/main as of last fetch)"
echo "  Version:  ${version:-?} in project.yml; latest tag ${tag:-none}"

here=$(git rev-parse --show-toplevel 2>/dev/null)
others=$(git worktree list --porcelain 2>/dev/null | awk -v here="$here" '
    /^worktree / {path = substr($0, 10)}
    /^branch / && path != here {sub("refs/heads/", "", $2); printf "%s ", $2}')
[[ -n "$others" ]] && echo "  Branches checked out elsewhere (other sessions; don't edit their files): $others"

if command -v gh >/dev/null; then
    prs=$(perl -e 'alarm shift; exec @ARGV' 5 gh pr list --state open \
        --json number,title,headRefName \
        --template '{{range .}}    #{{.number}} {{.title}} [{{.headRefName}}]{{"\n"}}{{end}}' 2>/dev/null)
    if [[ -n "$prs" ]]; then
        echo "  Open PRs:"
        printf '%s\n' "$prs"
    else
        echo "  Open PRs: none (or gh unavailable)"
    fi
fi

# Titles of the "Next up" items in docs/status.md (the bold lead of each numbered item).
if [[ -f docs/status.md ]]; then
    next=$(awk '/^## Next up/ {on=1; next} /^## / {on=0} on && /^[0-9]+\. \*\*/ {
        line = $0; sub(/^[0-9]+\. \*\*/, "", line); sub(/\*\*.*/, "", line); n++; printf "    %d. %s\n", n, line }' docs/status.md)
    [[ -n "$next" ]] && { echo "  Next up (docs/status.md):"; printf '%s\n' "$next"; }
fi

echo "  Start work: /task [task]   End the session: /handoff"
exit 0
