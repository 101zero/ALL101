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
  TMPZIP="$(mktemp -u /tmp/nuclei-templates_XXXX.zip)"
  TMPZIP="/tmp/nuclei-templates.zip"
  # keep the link exactly as requested
  wget -q -O "$TMPZIP" "https://github.com/projectdiscovery/nuclei-templates/archive/refs/tags/v10.3.1.zip" || log "WARN: templates download failed"
  mkdir -p "$TEMPLATES_PATH"
  # unzip into /tmp
  unzip -o "$TMPZIP" -d /tmp >/dev/null 2>&1 || true

  # ==== find the extracted directory dynamically ====
  # There are two common cases:
  # 1) zip contains a single top-level folder (e.g. /tmp/nuclei-templates-10.3.1)
  # 2) zip contains many files at top level (rare). We handle case 1 primarily.
  EXTRACTED_DIR=""
  # prefer directories that start with 'nuclei-templates'
  for d in /tmp/nuclei-templates*; do
    [ -e "$d" ] || continue
    # skip the zip file itself
    if [ -f "$d" ]; then
      continue
    fi
    # ensure it's a directory and not the destination path
    if [ -d "$d" ] && [ "$(basename "$d")" != "$(basename "$TEMPLATES_PATH")" ]; then
      EXTRACTED_DIR="$d"
      break
    fi
  done

  if [ -n "$EXTRACTED_DIR" ]; then
    log "moving extracted templates from $EXTRACTED_DIR -> $TEMPLATES_PATH"
    # move contents (preserve if exists, but allow overwrite)
    mkdir -p "$TEMPLATES_PATH"
    # use mv of contents; if target already has files, mv will merge/overwrite
    mv "$EXTRACTED_DIR"/* "$TEMPLATES_PATH"/ 2>/dev/null || true
    # if there are hidden files in extracted dir, move them too
    shopt_saved=""
    if command -v shopt >/dev/null 2>&1; then
      # enable dotglob temporarily (bash)
      shopt -s dotglob 2>/dev/null || true
      mv "$EXTRACTED_DIR"/.* "$TEMPLATES_PATH"/ 2>/dev/null || true
      # restore not strictly necessary in ephemeral container
    fi
    # cleanup extracted dir if empty
    rmdir --ignore-fail-on-non-empty "$EXTRACTED_DIR" 2>/dev/null || true
  else
    # fallback: maybe unzip put files directly into /tmp; try to move nuclei-templates* files
    log "WARN: could not find an extracted directory named /tmp/nuclei-templates*; trying to detect files"
    # if unzip produced a directory named exactly 'nuclei-templates', move it
    if [ -d /tmp/nuclei-templates ]; then
      log "Found /tmp/nuclei-templates, moving to $TEMPLATES_PATH"
      mv /tmp/nuclei-templates/* "$TEMPLATES_PATH"/ 2>/dev/null || true
    else
      # as last resort, list zip contents and try to extract names
      FIRST_DIR="$(unzip -Z1 "$TMPZIP" 2>/dev/null | head -n1 | cut -d'/' -f1 || true)"
      if [ -n "$FIRST_DIR" ] && [ -d "/tmp/$FIRST_DIR" ]; then
        log "Detected first-level folder /tmp/$FIRST_DIR, moving contents"
        mv "/tmp/$FIRST_DIR"/* "$TEMPLATES_PATH"/ 2>/dev/null || true
      else
        log "WARN: unable to automatically place templates - $TEMPLATES_PATH may still be empty"
      fi
    fi
  fi

  rm -f "$TMPZIP" 2>/dev/null || true
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
