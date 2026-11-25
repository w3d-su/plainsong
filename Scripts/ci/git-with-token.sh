#!/bin/bash
# Runs git against github.com with GH_TOKEN, without storing the token.
#
# A token in the remote URL or left by actions/checkout stays in .git/config,
# where every later step and any uploaded copy of the checkout can read it.
# Here it is in this one git process's environment only (GIT_CONFIG_*), not in
# the command line or on disk.
#
# Usage: GH_TOKEN=... Scripts/ci/git-with-token.sh <git arguments>
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is not set}"
credentials="$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="http.https://github.com/.extraheader"
export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $credentials"
exec git "$@"
