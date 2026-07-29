#!/usr/bin/env bash
# fm-codex-cage.sh - launch Codex inside Firstmate's external macOS cage.
#
# Usage:
#   fm-codex-cage.sh --worktree <dir> --task-data-dir <dir> \
#     --status-path <file> [--notify-path <file>] [--fm-home <dir>] -- \
#     codex <args...>
#
# The wrapper fails closed unless it can apply the adjacent Seatbelt profile.
# It resolves the task's worktree and Git metadata before entering the cage,
# grants only the exact Firstmate lifecycle paths named by the caller, and
# rebuilds the environment from a non-secret allowlist.
# The Seatbelt profile permits the discovered Codex native process to read its own
# CODEX_HOME and one exact resolved canonical global-rules file so startup and
# ChatGPT authentication work, but model-launched child processes have a
# different executable path and cannot read either protected surface.
# The no-mistakes daemon remains reachable only through its exact Unix socket;
# every loopback TCP destination, including Chrome debugging ports, is denied.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="$SCRIPT_DIR/fm-codex-cage.sb"
GH_PUBLIC_CLONE_HELPER="$SCRIPT_DIR/fm-gh-public-clone.sh"
SANDBOX_EXEC=/usr/bin/sandbox-exec
TLS_TRUST_DIR=/private/etc/ssl
CA_CERTIFICATE="$TLS_TRUST_DIR/cert.pem"
DEVELOPER_DIR_VALUE=/Library/Developer/CommandLineTools

die() {
  printf 'fm-codex-cage: %s\n' "$*" >&2
  exit 2
}

canonical_dir() {
  local path=$1
  [ -d "$path" ] || die "directory does not exist: $path"
  (cd "$path" && pwd -P)
}

canonical_file_target() {
  local path=$1 parent base
  case "$path" in
    /*) ;;
    *) die "file path must be absolute: $path" ;;
  esac
  parent=$(canonical_dir "$(dirname "$path")")
  base=$(basename "$path")
  printf '%s/%s\n' "$parent" "$base"
}

resolve_symlinks() {
  local target=$1 link parent hops=0
  case "$target" in
    /*) ;;
    *) target="$PWD/$target" ;;
  esac
  while [ -L "$target" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 40 ] || die "too many symbolic links while resolving: $1"
    link=$(readlink "$target")
    case "$link" in
      /*) target=$link ;;
      *)
        parent=$(cd "$(dirname "$target")" && pwd -P)
        target="$parent/$link"
        ;;
    esac
  done
  parent=$(cd "$(dirname "$target")" && pwd -P)
  printf '%s/%s\n' "$parent" "$(basename "$target")"
}

path_is_within() {
  local parent=$1 child=$2
  [ "$child" = "$parent" ] || [ "${child#"$parent"/}" != "$child" ]
}

is_approved_global_rules_target() {
  local home=$1 codex_home=$2 target=$3
  case "$target" in
    "$home/AGENTS.md"|"$home/.agents.md"|"$home/.claude/CLAUDE.md"|\
      "$codex_home/AGENTS.md") return 0 ;;
    *) return 1 ;;
  esac
}

discover_global_rules_file() {
  local home=$1 codex_home=$2 alias target resolved=
  for alias in \
    "$home/AGENTS.md" \
    "$codex_home/AGENTS.md" \
    "$home/.agents.md"; do
    if [ ! -e "$alias" ] && [ ! -L "$alias" ]; then
      continue
    fi
    target=$(resolve_symlinks "$alias")
    is_approved_global_rules_target "$home" "$codex_home" "$target" \
      || die "global rules target is outside the approved canonical locations: $alias -> $target"
    [ -f "$target" ] \
      || die "global rules target is missing or not a regular file: $alias -> $target"
    [ -r "$target" ] \
      || die "global rules target is not readable: $alias -> $target"
    if [ -n "$resolved" ] && [ "$resolved" != "$target" ]; then
      die "global rules aliases resolve to conflicting files: $resolved and $target"
    fi
    resolved=$target
  done
  printf '%s\n' "${resolved:-/dev/null}"
}

discover_codex_native() {
  local launcher=$1 install_root=$2 architecture platform candidate matches
  if /usr/bin/file "$launcher" | grep -q 'Mach-O'; then
    printf '%s\n' "$launcher"
    return 0
  fi
  architecture=$(/usr/bin/uname -m)
  case "$architecture" in
    arm64) platform=aarch64-apple-darwin ;;
    x86_64) platform=x86_64-apple-darwin ;;
    *) die "unsupported macOS architecture: $architecture" ;;
  esac
  matches=
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    matches="${matches}${matches:+
}$candidate"
  done < <(
    find "$install_root" -type f -path "*/vendor/$platform/bin/codex" -perm -111 -print
  )
  case "$matches" in
    '') die "could not find the Codex native binary below $install_root" ;;
    *$'\n'*) die "multiple Codex native binaries matched below $install_root" ;;
  esac
  resolve_symlinks "$matches"
}

safe_optional_dir() {
  local path=${1:-}
  if [ -n "$path" ]; then
    canonical_dir "$path"
  else
    printf '/dev/null\n'
  fi
}

safe_optional_file() {
  local path=${1:-}
  if [ -n "$path" ]; then
    canonical_file_target "$path"
  else
    printf '/dev/null\n'
  fi
}

# shellcheck disable=SC2329  # Invoked indirectly by the traps installed below.
cleanup() {
  case "${CAGE_TMP:-}" in
    /private/tmp/fm-codex-cage.*)
      /bin/rm -rf -- "$CAGE_TMP"
      ;;
  esac
}

WORKTREE=
TASK_DATA_DIR=
STATUS_PATH=
NOTIFY_PATH=
FM_HOME_VALUE=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --worktree)
      [ "$#" -ge 2 ] || die "--worktree requires a value"
      WORKTREE=$2
      shift 2
      ;;
    --task-data-dir)
      [ "$#" -ge 2 ] || die "--task-data-dir requires a value"
      TASK_DATA_DIR=$2
      shift 2
      ;;
    --status-path)
      [ "$#" -ge 2 ] || die "--status-path requires a value"
      STATUS_PATH=$2
      shift 2
      ;;
    --notify-path)
      [ "$#" -ge 2 ] || die "--notify-path requires a value"
      NOTIFY_PATH=$2
      shift 2
      ;;
    --fm-home)
      [ "$#" -ge 2 ] || die "--fm-home requires a value"
      FM_HOME_VALUE=$2
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$WORKTREE" ] || die "--worktree is required"
[ -n "$STATUS_PATH" ] || die "--status-path is required"
[ "$#" -gt 0 ] || die "a Codex command is required after --"

case "$(/usr/bin/uname -s)" in
  Darwin) ;;
  *) die "no verified external Codex cage is available on this operating system" ;;
esac
[ -x "$SANDBOX_EXEC" ] || die "macOS sandbox-exec is unavailable"
[ -r "$PROFILE" ] || die "Seatbelt profile is unavailable: $PROFILE"
[ -x "$GH_PUBLIC_CLONE_HELPER" ] \
  || die "public GitHub clone helper is unavailable: $GH_PUBLIC_CLONE_HELPER"
[ -d "$TLS_TRUST_DIR" ] && [ -r "$TLS_TRUST_DIR" ] \
  || die "macOS TLS trust directory is unavailable: $TLS_TRUST_DIR"
[ -f "$CA_CERTIFICATE" ] && [ -r "$CA_CERTIFICATE" ] \
  || die "macOS public CA bundle is unavailable: $CA_CERTIFICATE"
[ -d "$DEVELOPER_DIR_VALUE" ] && [ -r "$DEVELOPER_DIR_VALUE" ] \
  || die "macOS Command Line Tools are unavailable: $DEVELOPER_DIR_VALUE"

WORKTREE=$(canonical_dir "$WORKTREE")
CURRENT_DIR=$(pwd -P)
path_is_within "$WORKTREE" "$CURRENT_DIR" \
  || die "current directory is outside the declared worktree: $CURRENT_DIR"
TASK_DATA_DIR=$(safe_optional_dir "$TASK_DATA_DIR")
STATUS_PATH=$(canonical_file_target "$STATUS_PATH")
NOTIFY_PATH=$(safe_optional_file "$NOTIFY_PATH")
if [ -n "$FM_HOME_VALUE" ]; then
  FM_HOME_VALUE=$(canonical_dir "$FM_HOME_VALUE")
else
  FM_HOME_VALUE=$WORKTREE
fi

case "$1" in
  */*) CODEX_LAUNCHER=$1 ;;
  *) CODEX_LAUNCHER=$(command -v "$1" || true) ;;
esac
[ -n "$CODEX_LAUNCHER" ] && [ -x "$CODEX_LAUNCHER" ] \
  || die "Codex executable is unavailable: $1"
[ "$(basename "$CODEX_LAUNCHER")" = codex ] \
  || die "the caged command must be the Codex CLI"
CODEX_LAUNCHER=$(resolve_symlinks "$CODEX_LAUNCHER")

if /usr/bin/file "$CODEX_LAUNCHER" | grep -q 'Mach-O'; then
  CODEX_INSTALL_ROOT=$(canonical_dir "$(dirname "$CODEX_LAUNCHER")")
else
  CODEX_INSTALL_ROOT=$(canonical_dir "$(dirname "$CODEX_LAUNCHER")/..")
fi
CODEX_NATIVE=$(discover_codex_native "$CODEX_LAUNCHER" "$CODEX_INSTALL_ROOT")

HOME_VALUE=${HOME:-}
[ -n "$HOME_VALUE" ] || die "HOME is required"
HOME_VALUE=$(canonical_dir "$HOME_VALUE")
CODEX_HOME_VALUE=${CODEX_HOME:-"$HOME_VALUE/.codex"}
CODEX_HOME_VALUE=$(canonical_dir "$CODEX_HOME_VALUE")
GLOBAL_RULES_FILE=$(discover_global_rules_file "$HOME_VALUE" "$CODEX_HOME_VALUE")

GIT_DIR=$(git -C "$WORKTREE" rev-parse --path-format=absolute --git-dir 2>/dev/null) \
  || die "worktree is not a Git worktree: $WORKTREE"
GIT_COMMON_DIR=$(git -C "$WORKTREE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || die "could not resolve Git common directory: $WORKTREE"
GIT_DIR=$(canonical_dir "$GIT_DIR")
GIT_COMMON_DIR=$(canonical_dir "$GIT_COMMON_DIR")

LOCAL_BIN_DIR=$(canonical_dir "$(dirname "$(command -v codex)")")

NPX_COMMAND=$(command -v npx || true)
if [ -n "$NPX_COMMAND" ]; then
  NPX_REAL=$(resolve_symlinks "$NPX_COMMAND")
  case "$NPX_REAL" in
    */lib/node_modules/*) NPX_ROOT=${NPX_REAL%%/lib/node_modules/*} ;;
    *) NPX_ROOT=$(dirname "$NPX_REAL") ;;
  esac
  NPX_ROOT=$(canonical_dir "$NPX_ROOT")
  NPX_BIN_DIR=$(canonical_dir "$(dirname "$NPX_COMMAND")")
else
  NPX_ROOT=/dev/null
  NPX_BIN_DIR=/dev/null
fi

NO_MISTAKES_COMMAND=$(command -v no-mistakes || true)
if [ -n "$NO_MISTAKES_COMMAND" ]; then
  NO_MISTAKES_REAL=$(resolve_symlinks "$NO_MISTAKES_COMMAND")
  NO_MISTAKES_BIN_DIR=$(canonical_dir "$(dirname "$NO_MISTAKES_REAL")")
else
  NO_MISTAKES_BIN_DIR=/dev/null
fi
NO_MISTAKES_SOCKET="$HOME_VALUE/.no-mistakes/socket"

CAGE_TMP=$(/usr/bin/mktemp -d /private/tmp/fm-codex-cage.XXXXXX)
trap cleanup EXIT HUP INT TERM
/bin/chmod 700 "$CAGE_TMP"
/bin/mkdir -p \
  "$CAGE_TMP/bin" \
  "$CAGE_TMP/gh" \
  "$CAGE_TMP/npm" \
  "$CAGE_TMP/xdg" \
  "$CAGE_TMP/zsh"
/bin/cp "$GH_PUBLIC_CLONE_HELPER" "$CAGE_TMP/bin/gh"
/bin/chmod 500 "$CAGE_TMP/bin/gh"
# shellcheck disable=SC2016  # The login shell must expand these inside the cage.
printf 'export PATH="${TMPDIR%%/}/bin:$PATH"\n' >"$CAGE_TMP/zsh/.zprofile"

GIT_CONFIG="$CAGE_TMP/gitconfig"
GIT_NAME=$(git config --global --get user.name 2>/dev/null || true)
GIT_EMAIL=$(git config --global --get user.email 2>/dev/null || true)
git config --file "$GIT_CONFIG" commit.gpgsign false
if [ -n "$GIT_NAME" ]; then
  git config --file "$GIT_CONFIG" user.name "$GIT_NAME"
fi
if [ -n "$GIT_EMAIL" ]; then
  git config --file "$GIT_CONFIG" user.email "$GIT_EMAIL"
fi

CAGE_PATH="$CAGE_TMP/bin:$LOCAL_BIN_DIR:$NPX_BIN_DIR:$NO_MISTAKES_BIN_DIR:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

set +e
/usr/bin/env -i \
  HOME="$HOME_VALUE" \
  USER="${USER:-}" \
  LOGNAME="${LOGNAME:-}" \
  SHELL=/bin/zsh \
  PATH="$CAGE_PATH" \
  TERM="${TERM:-xterm-256color}" \
  LANG="${LANG:-en_US.UTF-8}" \
  LC_CTYPE="${LC_CTYPE:-UTF-8}" \
  TMPDIR="$CAGE_TMP/" \
  ZDOTDIR="$CAGE_TMP/zsh" \
  CODEX_HOME="$CODEX_HOME_VALUE" \
  SSL_CERT_FILE="$CA_CERTIFICATE" \
  DEVELOPER_DIR="$DEVELOPER_DIR_VALUE" \
  FM_HOME="$FM_HOME_VALUE" \
  GIT_CONFIG_GLOBAL="$GIT_CONFIG" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_TERMINAL_PROMPT=0 \
  GH_CONFIG_DIR="$CAGE_TMP/gh" \
  NPM_CONFIG_CACHE="$CAGE_TMP/npm" \
  XDG_CONFIG_HOME="$CAGE_TMP/xdg" \
  NO_MISTAKES_TELEMETRY=off \
  "$SANDBOX_EXEC" \
    -f "$PROFILE" \
    -D "WORKTREE=$WORKTREE" \
    -D "GIT_DIR=$GIT_DIR" \
    -D "GIT_COMMON_DIR=$GIT_COMMON_DIR" \
    -D "TASK_DATA_DIR=$TASK_DATA_DIR" \
    -D "STATUS_PATH=$STATUS_PATH" \
    -D "NOTIFY_PATH=$NOTIFY_PATH" \
    -D "CAGE_TMP=$CAGE_TMP" \
    -D "CODEX_HOME=$CODEX_HOME_VALUE" \
    -D "GLOBAL_RULES_FILE=$GLOBAL_RULES_FILE" \
    -D "TLS_TRUST_DIR=$TLS_TRUST_DIR" \
    -D "CODEX_NATIVE=$CODEX_NATIVE" \
    -D "CODEX_INSTALL_ROOT=$CODEX_INSTALL_ROOT" \
    -D "LOCAL_BIN_DIR=$LOCAL_BIN_DIR" \
    -D "NPX_ROOT=$NPX_ROOT" \
    -D "NO_MISTAKES_BIN_DIR=$NO_MISTAKES_BIN_DIR" \
    -D "NO_MISTAKES_SOCKET=$NO_MISTAKES_SOCKET" \
    "$@"
status=$?
set -e

exit "$status"
