#!/usr/bin/env bash
set -euo pipefail

TARGETS_PATH="${TARGETS_PATH:-/data/5subdomains.txt}"
PROVIDER_PATH="${PROVIDER_PATH:-/secrets/provider.yaml}"
TEMPLATES_PATH="${TEMPLATES_PATH:-/nuclei-templates}"

log(){ echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }

log "START - nuclei-notify (pipe mode)"
log "TARGETS=$TARGETS_PATH PROVIDER=$PROVIDER_PATH TEMPLATES=$TEMPLATES_PATH"

# checks
if [ ! -f "$PROVIDER_PATH" ]; then
  log "ERROR provider file missing at $PROVIDER_PATH"
  exit 2
fi

if [ ! -f "$TARGETS_PATH" ]; then
  log "ERROR targets file missing at $TARGETS_PATH"
  exit 2
fi

# ensure templates exist; download official tag if missing
if [ ! -d "$TEMPLATES_PATH" ] || [ -z "$(ls -A "$TEMPLATES_PATH" 2>/dev/null || true)" ]; then
  log "nuclei-templates not present, downloading..."
  TMPZIP="/tmp/nuclei-templates.zip"
  # kept exactly the requested link
  wget -q -O "$TMPZIP" "https://github.com/projectdiscovery/nuclei-templates/archive/refs/tags/v10.3.1.zip" || log "WARN: templates download failed"
  mkdir -p "$TEMPLATES_PATH"
  # unzip into a temp dir to avoid assumptions on top-level folder name
  EXTRACT_DIR="/tmp/nuclei-templates-extract-$$"
  rm -rf "$EXTRACT_DIR"
  mkdir -p "$EXTRACT_DIR"
  unzip -o "$TMPZIP" -d "$EXTRACT_DIR" >/dev/null 2>&1 || true

  # find first extracted directory that looks like nuclei-templates*
  FOUND=""
  for d in "$EXTRACT_DIR"/*; do
    [ -e "$d" ] || continue
    if [ -d "$d" ]; then
      FOUND="$d"
      break
    fi
  done

  if [ -n "$FOUND" ]; then
    log "moving extracted templates from $FOUND -> $TEMPLATES_PATH"
    # copy contents (including hidden) into target
    mkdir -p "$TEMPLATES_PATH"
    # enable dotglob in a subshell to move hidden files too (if bash supports)
    ( shopt -s dotglob 2>/dev/null || true; cp -r "$FOUND"/* "$TEMPLATES_PATH"/ ) 2>/dev/null || true
  else
    # maybe unzip produced files directly into extract dir
    if [ -n "$(ls -A "$EXTRACT_DIR" 2>/dev/null || true)" ]; then
      log "No single top-dir found; copying extracted files to $TEMPLATES_PATH"
      ( shopt -s dotglob 2>/dev/null || true; cp -r "$EXTRACT_DIR"/* "$TEMPLATES_PATH"/ ) 2>/dev/null || true
    else
      log "WARN: unzip produced nothing expected; $TEMPLATES_PATH may still be empty"
    fi
  fi

  # cleanup
  rm -rf "$EXTRACT_DIR"
  rm -f "$TMPZIP" 2>/dev/null || true
fi

# --- PRIMARY: exact command requested (pipe, no JSON flag) ---
log "Running: nuclei -l $TARGETS_PATH -t $TEMPLATES_PATH -s high,critical -as -silent | notify -pc $PROVIDER_PATH"
set +e
nuclei -l "$TARGETS_PATH" -t "$TEMPLATES_PATH" -s high,critical -as -silent | notify -pc "$PROVIDER_PATH"
PIPE_EXIT="$?"
set -e

if [ "$PIPE_EXIT" -eq 0 ]; then
  log "PIPE OK: nuclei output piped to notify successfully"
  exit 0
fi

# --- FALLBACK (only if direct pipe fails) ---
log "PIPE FAILED (exit $PIPE_EXIT). Falling back: capture nuclei output to temp file and retry notify with -input"

TMPFILE="$(mktemp /tmp/nuclei_out_XXXX)"
# produce plain text output (no -json): write to file then call notify -input
set +e
nuclei -l "$TARGETS_PATH" -t "$TEMPLATES_PATH" -s high,critical -silent -o "$TMPFILE"
NUC_EXIT="$?"
set -e

if [ "$NUC_EXIT" -ne 0 ] || [ ! -s "$TMPFILE" ]; then
  log "Fallback nuclei produced no output or failed (exit $NUC_EXIT). Cleaning up and exiting."
  rm -f "$TMPFILE"
  exit 0
fi

log "Retrying notify with -input on $TMPFILE"
set +e
notify -pc "$PROVIDER_PATH" -input "$TMPFILE"
NOTIFY_EXIT="$?"
set -e

if [ "$NOTIFY_EXIT" -eq 0 ]; then
  log "Fallback notify OK"
  rm -f "$TMPFILE"
  exit 0
else
  log "Fallback notify failed (exit $NOTIFY_EXIT). Keeping $TMPFILE for investigation."
  exit 0
fi
