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

# ensure templates exist; download official master if missing
if [ ! -d "$TEMPLATES_PATH" ] || [ -z "$(ls -A "$TEMPLATES_PATH" 2>/dev/null || true)" ]; then
  log "nuclei-templates not present, downloading..."
  TMPZIP="/tmp/nuclei-templates.zip"
  wget -q -O "$TMPZIP" "https://github.com/projectdiscovery/nuclei-templates/archive/refs/heads/master.zip" || log "WARN: templates download failed"
  mkdir -p "$TEMPLATES_PATH"
  unzip -o "$TMPZIP" -d /tmp || true
  if [ -d /tmp/nuclei-templates-master ]; then
    mv /tmp/nuclei-templates-master/* "$TEMPLATES_PATH"/ || true
  fi
  rm -f "$TMPZIP"
fi

# --- PRIMARY: exact command requested (pipe, no JSON flag) ---
log "Running: nuclei -l $TARGETS_PATH -t $TEMPLATES_PATH -s high,critical -silent | notify -pc $PROVIDER_PATH"
set +e
nuclei -l "$TARGETS_PATH" -t "$TEMPLATES_PATH" -s high,critical -silent | notify -pc "$PROVIDER_PATH"
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
