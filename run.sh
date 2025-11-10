#!/usr/bin/env bash

set -euo pipefail

TARGETS_PATH="${TARGETS_PATH:-/data/5subdomains.txt}"
PROVIDER_PATH="${PROVIDER_PATH:-/secrets/provider.yaml}"
TEMPLATES_PATH="${TEMPLATES_PATH:-/nuclei-templates}"

log(){ echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }

log "START - nuclei-notify (pipe mode)"
log "TARGETS=$TARGETS_PATH PROVIDER=$PROVIDER_PATH TEMPLATES=$TEMPLATES_PATH"

# Check binaries exist
if ! command -v nuclei &> /dev/null; then
  log "ERROR: nuclei binary not found in PATH"
  exit 1
fi

if ! command -v notify &> /dev/null; then
  log "ERROR: notify binary not found in PATH"
  exit 1
fi

# Checks
if [ ! -f "$PROVIDER_PATH" ]; then
  log "ERROR provider file missing at $PROVIDER_PATH"
  exit 2
fi

if [ ! -f "$TARGETS_PATH" ]; then
  log "ERROR targets file missing at $TARGETS_PATH"
  exit 2
fi

if [ ! -s "$TARGETS_PATH" ]; then
  log "ERROR targets file is empty at $TARGETS_PATH"
  exit 2
fi

# Ensure templates exist; download official master if missing
if [ ! -d "$TEMPLATES_PATH" ] || [ -z "$(ls -A "$TEMPLATES_PATH" 2>/dev/null || true)" ]; then
  log "nuclei-templates not present, downloading..."
  
  TEMP_DIR=$(mktemp -d)
  TMPZIP="$TEMP_DIR/nuclei-templates.zip"
  
  # Try to download from main branch (latest)
  if ! wget -q -O "$TMPZIP" "https://github.com/projectdiscovery/nuclei-templates/archive/refs/heads/main.zip"; then
    log "WARN: main branch download failed, trying v10.3.1 tag..."
    if ! wget -q -O "$TMPZIP" "https://github.com/projectdiscovery/nuclei-templates/archive/refs/tags/v10.3.1.zip"; then
      log "ERROR: templates download failed completely"
      rm -rf "$TEMP_DIR"
      exit 1
    fi
  fi
  
  mkdir -p "$TEMPLATES_PATH"
  
  if ! unzip -q -o "$TMPZIP" -d "$TEMP_DIR"; then
    log "ERROR: failed to extract templates"
    rm -rf "$TEMP_DIR"
    exit 1
  fi
  
  # Handle different archive structures
  if [ -d "$TEMP_DIR/nuclei-templates-main" ]; then
    mv "$TEMP_DIR/nuclei-templates-main"/* "$TEMPLATES_PATH"/ || {
      log "ERROR: failed to move templates-main"
      rm -rf "$TEMP_DIR"
      exit 1
    }
  elif [ -d "$TEMP_DIR/nuclei-templates-10.3.1" ]; then
    mv "$TEMP_DIR/nuclei-templates-10.3.1"/* "$TEMPLATES_PATH"/ || {
      log "ERROR: failed to move templates-10.3.1"
      rm -rf "$TEMP_DIR"
      exit 1
    }
  elif [ -d "$TEMP_DIR/nuclei-templates-master" ]; then
    mv "$TEMP_DIR/nuclei-templates-master"/* "$TEMPLATES_PATH"/ || {
      log "ERROR: failed to move templates-master"
      rm -rf "$TEMP_DIR"
      exit 1
    }
  else
    log "ERROR: unexpected templates archive structure in $TEMP_DIR"
    ls -la "$TEMP_DIR"
    rm -rf "$TEMP_DIR"
    exit 1
  fi
  
  rm -rf "$TEMP_DIR"
  log "Templates downloaded successfully"
fi

# Verify templates directory is not empty
if [ -z "$(ls -A "$TEMPLATES_PATH" 2>/dev/null || true)" ]; then
  log "ERROR: templates directory is empty after setup"
  exit 1
fi

# --- PRIMARY: exact command requested (pipe, no JSON flag) ---
log "Running: nuclei -l $TARGETS_PATH -t $TEMPLATES_PATH -s high,critical -as -silent | notify -pc $PROVIDER_PATH"

# Create temp file for fallback
TMPFILE="$(mktemp /tmp/nuclei_out_XXXXXX)"

# Try direct pipe first
# Use tee to capture output while piping
set +e
nuclei -l "$TARGETS_PATH" -t "$TEMPLATES_PATH" -s high,critical -as -silent 2>&1 | tee "$TMPFILE" | notify -pc "$PROVIDER_PATH"
PIPE_EXIT="${PIPESTATUS[0]}"  # nuclei exit code
NOTIFY_EXIT="${PIPESTATUS[2]}"  # notify exit code
set -e

# Check results
if [ "$PIPE_EXIT" -eq 0 ] && [ "$NOTIFY_EXIT" -eq 0 ]; then
  if [ -s "$TMPFILE" ]; then
    log "PIPE OK: nuclei output piped to notify successfully"
    log "Output preview (first 5 lines):"
    head -n 5 "$TMPFILE" || true
  else
    log "INFO: No findings detected (empty output)"
  fi
  rm -f "$TMPFILE"
  exit 0
elif [ "$PIPE_EXIT" -ne 0 ]; then
  log "WARN: nuclei failed with exit code $PIPE_EXIT"
elif [ "$NOTIFY_EXIT" -ne 0 ]; then
  log "WARN: notify failed with exit code $NOTIFY_EXIT"
fi

# --- FALLBACK (only if pipe failed) ---
log "PIPE failed. Trying fallback: capture nuclei output and retry notify with -input"

# If TMPFILE is empty or doesn't exist, run nuclei again
if [ ! -s "$TMPFILE" ]; then
  set +e
  nuclei -l "$TARGETS_PATH" -t "$TEMPLATES_PATH" -s high,critical -silent -o "$TMPFILE" 2>&1
  NUC_EXIT=$?
  set -e
  
  if [ "$NUC_EXIT" -ne 0 ]; then
    log "WARN: fallback nuclei exited with code $NUC_EXIT"
  fi
fi

if [ ! -s "$TMPFILE" ]; then
  log "INFO: No findings detected (empty output)"
  rm -f "$TMPFILE"
  exit 0
fi

log "Retrying notify with -input on $TMPFILE"
set +e
notify -pc "$PROVIDER_PATH" -input "$TMPFILE"
NOTIFY_EXIT=$?
set -e

if [ "$NOTIFY_EXIT" -eq 0 ]; then
  log "Fallback notify OK"
  rm -f "$TMPFILE"
  exit 0
else
  log "ERROR: Fallback notify failed with exit code $NOTIFY_EXIT"
  log "Keeping $TMPFILE for investigation"
  exit $NOTIFY_EXIT
fi

