#!/usr/bin/env bash
# fm-gh-public-clone.sh - credential-free public GitHub clone compatibility.
#
# The Codex cage exposes this script as `gh`.
# It supports only `gh repo clone OWNER/REPO [DIRECTORY] [-- GIT_FLAGS...]`.
# Authenticated GitHub operations stay outside the cage so a model-launched
# process can never retrieve or print the captain's GitHub token.
set -eu

die() {
  printf 'caged gh: %s\n' "$*" >&2
  exit 2
}

[ "$#" -ge 3 ] || die "only public 'gh repo clone OWNER/REPO' is supported"
[ "$1" = repo ] && [ "$2" = clone ] \
  || die "only public 'gh repo clone OWNER/REPO' is supported"
shift 2

repository=$1
shift
case "$repository" in
  */*)
    owner=${repository%%/*}
    name=${repository#*/}
    ;;
  *) die "repository must use OWNER/REPO syntax" ;;
esac
[ -n "$owner" ] && [ -n "$name" ] && [ "${name#*/}" = "$name" ] \
  || die "repository must use OWNER/REPO syntax"
case "$owner$name" in
  *[!A-Za-z0-9_.-]*) die "repository contains unsupported characters" ;;
esac
case "$name" in
  *.git) name=${name%.git} ;;
esac
[ -n "$name" ] || die "repository name is empty"

git_args=(clone "https://github.com/$owner/$name.git")
if [ "$#" -gt 0 ] && [ "$1" != -- ]; then
  case "$1" in
    -*) die "gh clone flags are unsupported before '--'" ;;
    *) git_args+=("$1"); shift ;;
  esac
fi
if [ "$#" -gt 0 ]; then
  [ "$1" = -- ] || die "unexpected argument: $1"
  shift
  git_args+=("$@")
fi

exec git "${git_args[@]}"
