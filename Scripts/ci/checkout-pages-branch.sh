#!/bin/bash
# Checks out the published gh-pages branch into <directory>, or starts an
# orphan branch only when the remote answers that it has no such branch.
#
# `git ls-remote --exit-code` exits 2 for "no matching ref" and with another
# code when it could not ask (network, authentication). Only 2 may start an
# empty branch: treating every failure as "no branch yet" would skip the
# publish workflow's downgrade check against the published feed and then push
# over it.
#
# With GH_TOKEN set, git runs through git-with-token.sh so the token is never
# written to <directory>/.git/config.
#
# Usage: checkout-pages-branch.sh <directory> <remote url> [branch]
set -euo pipefail

[[ $# -ge 2 && $# -le 3 ]] || { echo "usage: $0 <directory> <remote url> [branch]" >&2; exit 64; }
directory="$1" remote="$2" branch="${3:-gh-pages}"

run_git() {
    if [[ -n "${GH_TOKEN:-}" ]]; then
        "$(dirname "$0")/git-with-token.sh" "$@"
    else
        git "$@"
    fi
}

git init --quiet "$directory"
git -C "$directory" remote add origin "$remote"
status=0
run_git -C "$directory" ls-remote --exit-code --heads origin "$branch" > /dev/null || status=$?
case "$status" in
    0)
        run_git -C "$directory" fetch --quiet --depth 1 origin "$branch"
        git -C "$directory" checkout --quiet -b "$branch" FETCH_HEAD
        echo "checked out the published $branch"
        ;;
    2)
        git -C "$directory" checkout --quiet --orphan "$branch"
        echo "the remote has no $branch branch: starting it"
        ;;
    *)
        echo "error: could not read $branch from the remote (git ls-remote exit $status); not publishing" >&2
        exit 1
        ;;
esac
