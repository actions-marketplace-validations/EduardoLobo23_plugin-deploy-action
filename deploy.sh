#!/usr/bin/env bash
#
# deploy.sh - core logic for the "Deploy Minecraft Plugin (SFTP)" action.
#
# Uploads a prebuilt plugin jar to a server's plugins/ folder over SFTP using
# OpenSSH's sftp client (batch mode). Upload-only: the jar loads on the server's
# next restart. See SPEC.md for the full behavior contract.
#
# NOTE: never enable `set -x` here — it would echo secrets into the log.

set -euo pipefail

# --- helpers ----------------------------------------------------------------

die() { echo "::error::$*"; exit 1; }
warn() { echo "::warning::$*"; }
info() { echo "$*"; }

cleanup() {
  # Best-effort removal of temp material (private key, known_hosts, batch file).
  rm -f "${KEY_FILE:-}" "${KH_FILE:-}" "${BATCH_FILE:-}" 2>/dev/null || true
}
trap cleanup EXIT

# --- 1. read + validate inputs ---------------------------------------------

HOST="${INPUT_HOST:-}"
PORT="${INPUT_PORT:-22}"
USERNAME="${INPUT_USERNAME:-}"
PASSWORD="${INPUT_PASSWORD:-}"
PRIVATE_KEY="${INPUT_PRIVATE_KEY:-}"
LOCAL_PATH="${INPUT_LOCAL_PATH:-}"
REMOTE_PATH="${INPUT_REMOTE_PATH:-plugins/}"
CLEAN_PATTERN="${INPUT_CLEAN_PATTERN:-}"
KNOWN_HOSTS="${INPUT_KNOWN_HOSTS:-}"
DRY_RUN="${INPUT_DRY_RUN:-false}"

# --- 2. mask secrets BEFORE they can reach the log --------------------------

if [ -n "$PASSWORD" ]; then
  echo "::add-mask::$PASSWORD"
fi
if [ -n "$PRIVATE_KEY" ]; then
  # Mask every line so multi-line PEM keys don't leak.
  while IFS= read -r _line; do
    [ -n "$_line" ] && echo "::add-mask::$_line"
  done <<< "$PRIVATE_KEY"
fi

[ -n "$HOST" ] || die "input 'host' is required."
[ -n "$USERNAME" ] || die "input 'username' is required."
[ -n "$LOCAL_PATH" ] || die "input 'local-path' is required."

# Exactly one authentication method.
if [ -n "$PASSWORD" ] && [ -n "$PRIVATE_KEY" ]; then
  die "provide only one of 'password' or 'private-key', not both."
fi
if [ -z "$PASSWORD" ] && [ -z "$PRIVATE_KEY" ]; then
  die "provide one of 'password' or 'private-key'."
fi

# Resolve local-path glob to a concrete list of files.
shopt -s nullglob
# shellcheck disable=SC2206  # intentional word-split + glob expansion
FILES=( $LOCAL_PATH )
shopt -u nullglob
if [ "${#FILES[@]}" -eq 0 ]; then
  die "local-path '$LOCAL_PATH' matched no files."
fi
info "Matched ${#FILES[@]} file(s) for upload:"
for f in "${FILES[@]}"; do info "  - $f"; done

# Normalize remote dir to a single trailing slash.
REMOTE_DIR="${REMOTE_PATH%/}/"

# --- 3. host key handling ---------------------------------------------------

SSH_OPTS=()
if [ -n "$KNOWN_HOSTS" ]; then
  KH_FILE="$(mktemp)"
  printf '%s\n' "$KNOWN_HOSTS" > "$KH_FILE"
  SSH_OPTS+=( -o "UserKnownHostsFile=$KH_FILE" -o "StrictHostKeyChecking=yes" )
  info "Host key pinning: enabled."
else
  warn "UNVERIFIED HOST — no 'known-hosts' provided. This connection is susceptible to MITM. Set 'known-hosts' for a secure deploy (see README)."
  SSH_OPTS+=( -o "UserKnownHostsFile=/dev/null" -o "GlobalKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" )
fi

# --- 4. auth setup ----------------------------------------------------------

# Base sftp invocation; auth-specific bits appended below.
SFTP_CMD=( sftp -P "$PORT" "${SSH_OPTS[@]}" )
RUNNER=()

if [ -n "$PRIVATE_KEY" ]; then
  KEY_FILE="$(mktemp)"
  printf '%s\n' "$PRIVATE_KEY" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  SFTP_CMD+=( -o "IdentitiesOnly=yes" -o "BatchMode=yes" -i "$KEY_FILE" )
else
  # Password auth: sshpass answers ssh's password prompt (BatchMode must stay off).
  if ! command -v sshpass >/dev/null 2>&1; then
    info "Installing sshpass..."
    sudo apt-get update -qq && sudo apt-get install -y -qq sshpass
  fi
  # BatchMode=no is REQUIRED: `sftp -b` implies BatchMode=yes, which suppresses
  # the password prompt so sshpass can never supply it (-> auth silently fails).
  # It's placed before `-b` on the command line, so ssh's first-value-wins rule
  # keeps BatchMode=no over the batchmode=yes that `-b` appends afterward.
  SFTP_CMD+=( -o "PreferredAuthentications=password,keyboard-interactive" -o "PubkeyAuthentication=no" -o "BatchMode=no" )
  export SSHPASS="$PASSWORD"
  RUNNER=( sshpass -e )
fi

# --- 5. build the sftp batch script ----------------------------------------

BATCH_FILE="$(mktemp)"
UPLOADED=()
TOTAL_BYTES=0

if [ "$DRY_RUN" = "true" ]; then
  info "DRY RUN — validating connection only, no writes."
  # A harmless listing proves auth + host reachability.
  printf 'ls -l %s\n' "$REMOTE_DIR" > "$BATCH_FILE"
else
  {
    # Optional cleanup of stale versioned jars. '-' prefix => ignore "no match".
    if [ -n "$CLEAN_PATTERN" ]; then
      printf -- '-rm "%s%s"\n' "$REMOTE_DIR" "$CLEAN_PATTERN"
    fi
    for f in "${FILES[@]}"; do
      base="$(basename "$f")"
      # Atomic upload: stream to .part, then rename over the final name.
      # OpenSSH's rename uses the posix-rename extension (atomic overwrite),
      # so a dropped connection never leaves a truncated, crash-on-load jar.
      printf 'put "%s" "%s%s.part"\n' "$f" "$REMOTE_DIR" "$base"
      printf 'rename "%s%s.part" "%s%s"\n' "$REMOTE_DIR" "$base" "$REMOTE_DIR" "$base"
      UPLOADED+=( "$base" )
      size="$(stat -c %s "$f" 2>/dev/null || echo 0)"
      TOTAL_BYTES=$(( TOTAL_BYTES + size ))
    done
  } > "$BATCH_FILE"
fi

# --- 6. run + set outputs ---------------------------------------------------

info "Connecting to ${USERNAME}@${HOST}:${PORT} ..."
if ! "${RUNNER[@]}" "${SFTP_CMD[@]}" -b "$BATCH_FILE" "${USERNAME}@${HOST}"; then
  die "sftp transfer failed. Check host/port/credentials and that '$REMOTE_DIR' exists on the server."
fi

if [ "$DRY_RUN" = "true" ]; then
  info "Dry run succeeded: connection and authentication are valid."
  UPLOADED_STR=""
  TOTAL_BYTES=0
else
  UPLOADED_STR="${UPLOADED[*]}"
  info "Uploaded ${#UPLOADED[@]} file(s) (${TOTAL_BYTES} bytes) to ${REMOTE_DIR}"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "uploaded-files=${UPLOADED_STR}"
    echo "remote-path=${REMOTE_DIR}"
    echo "bytes-transferred=${TOTAL_BYTES}"
  } >> "$GITHUB_OUTPUT"
fi
