#!/bin/zsh
# Pull the latest FinderSearch from upstream into this fork.
#
# Workflow:
#   main  – pristine copy of zeusinsight/FinderSearch, only ever fast-forwards
#   homy  – this fork's feature branch (Home dashboard, natural-language
#           search, OCR, duplicates, clean up, quick search, …)
#
# Running this script fetches upstream, fast-forwards main, then merges
# main into homy. Homy features live in their own files under
# Sources/FinderSearch with only small marked integration points in
# Model.swift, Sidebar.swift and App.swift, so merges normally resolve
# themselves. If a merge conflicts, resolve it, commit, and re-run.

set -euo pipefail
cd "${0:A:h:h}"

remote=upstream
if ! git remote get-url "$remote" >/dev/null 2>&1; then
    git remote add "$remote" https://github.com/zeusinsight/FinderSearch.git
fi

branch="$(git branch --show-current)"
if [[ "$branch" != homy ]]; then
    print -u2 "Run this from the 'homy' branch (currently on '$branch')."
    exit 1
fi

print "Fetching $remote…"
git fetch "$remote"

print "Fast-forwarding main…"
git fetch "$remote" main:main --force-with-lease 2>/dev/null \
    || git branch -f main "$remote/main"

print "Merging main into homy…"
if git merge --no-edit main; then
    print "Up to date: fork now includes $(git log -1 --format='%h %s' main)"
    print "Build with: ./scripts/build.sh"
else
    print -u2 "Merge conflicts – resolve them, then 'git commit' and re-run."
    exit 1
fi
