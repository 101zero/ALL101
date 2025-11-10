#!/usr/bin/env bash
set -euo pipefail

TARGETS_PATH="${TARGETS_PATH:-/data/5subdomains.txt}"
PROVIDER_PATH="${PROVIDER_PATH:-/secrets/provider.yaml}"
TEMPLATES_PATH="${TEMPLATES_PATH:-/nuclei-templates}"

log(){ echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }

log "START - nuclei-notify (pipe mode)"
log "TARGETS=$TARGETS_PATH PROVIDER=$PROVIDER_PATH TEMPLATES=$TEMPLATES_PATH"

# --- basic checks
if ! command -v nuclei >/dev/null 2>&1; then
  log "ERROR: nuclei binary not found in PATH"
  exit 3
fi

if ! command -v notify >/dev/null 2>&1; then
  log "ERROR: notify binary not found in PATH"
  exit 3
fi

if [ ! -f "$PROVIDER_PATH" ]; then
  log "ERROR: provider file missing at $PROVIDER_PATH"
  exit 2
fi

if [ ! -f "$TARGETS_PATH" ]; then
  log "ERROR: targets file missing at $TARGETS_PATH"
  exit 2
fi

# --- ensure templates exist: use nuclei updater (preferred)
if [ ! -d "$TEMPLATES_PATH" ] || [ -z "$(ls -A "$TEMPLATES_PATH" 2>/dev/null || true)" ]; then
  log "Templates not found locally at $TEMPLATES_PATH. Running nuclei -ut (update-templates)..."
  # try update, ignore output to keep logs clean
  if nuclei -ut >/dev/null 2>&1; then
    log "nuclei -ut succeeded"
  else
    log "WARN: nuclei -ut failed or produced no output; continuing (will detect templates dynamically)"
  fi
fi

# After running updater, try to detect where templates are installed.
# Common places: ~/.nuclei-templates, /root/.nuclei-templates, default that nuclei uses.
# If the configured TEMPLATES_PATH is empty but a default exists, we will prefer default by running nuclei without -t.
TEMPLATES_POPULATED=false
if [ -d "$TEMPLATES_PATH" ] && [ -n "$(ls -A "$TEMPLATES_PATH" 2>/dev/null || true)" ]; then
  TEMPLATES_POPULATED=true
else
  # check common default locations
  if [ -d "$HOME/.nuclei-templates" ] && [ -n "$(ls -A "$HOME/.nuclei-templates" 2>/dev/null || true)" ]; then
    log "Found templates at $HOME/.nuclei-templates"
    TEMPLATES_POPULATED=true
  elif [ -d "/root/.nuclei-templates" ] && [ -n "$(ls -A /root/.nuclei-templates 2>/dev/null || true)" ]; then
    log "Found templates at /root/.nuclei-templates"
    TEMPLATES_POPULATED=true
  fi
fi

# Helper to run nuclei -> notify pipe and capture exit code
run_pipe_with_t() {
  local t_arg="$1"  # empty => no -t, non-empty => -t "$t_arg"
  if [ -n "$t_arg" ]; then
    log "Running: nuclei -l $TARGETS_PATH -t $t_arg -s high,critical -silent | notify -pc $PROVIDER_PATH"
    set +e
    nuclei -l "$TARGETS_PATH" -t "$t_arg" -s high,critical -silent | notify -pc "$PROVIDER_PATH"
    PIPE_EXIT="$?"
    set -e
  else
    log "Running: nuclei -l $TARGETS_PATH -s high,critical -silent | notify -pc $PROVIDER_PATH (using default nuclei templates)"
    set +e
    nuclei -l "$TARGETS_PATH" -s high,critical -silent | notify -pc "$PROVIDER_PATH"
    PIPE_EXIT="$?"
    set -e
  fi
}

# --- PRIMARY execution: prefer using provided templates path if populated, otherwise run without -t
if [ "$TEMPLATES_POPULATED" = true ]; then
  # if configured dir populated -> use it
  if [ -d "$TEMPLATES_PATH" ] && [ -n "$(ls -A "$TEMPLATES_PATH" 2>/dev/null || true)" ]; then
    run_pipe_with_t "$TEMPLATES_PATH"
  else
    # fallback: try default nuclei location (no -t)
    run_pipe_with_t ""
  fi
else
  # templates not found at configured path; run without -t to let nuclei use its own location
  run_pipe_with_t ""
fi

# If pipe succeeded -> done
if [ "${PIPE_EXIT:-1}" -eq 0 ]; then
  log "PIPE OK: nuclei output piped to notify successfully"
  exit 0
fi

# --- FALLBACK: if pipe failed, capture nuclei output to a temp file and retry notify -input
log "PIPE FAILED (exit ${PIPE_EXIT:-unknown}). Falling back: capture nuclei output to temp file and retry notify with -input"

TMPFILE="$(mktemp /tmp/nuclei_out_XXXX.txt)"
# Try to run nuclei to file. Prefer using -t if templates dir is populated.
set +e
if [ "$TEMPLATES_POPULATED" = true ] && [ -d "$TEMPLATES_PATH" ] && [ -n "$(ls -A "$TEMPLATES_PATH" 2>/dev/null || true)" ]; then
  nuclei -l "$TARGETS_PATH" -t "$TEMPLATES_PATH" -s high,critical -silent -o "$TMPFILE"
  NUC_EXIT="$?"
else
  nuclei -l "$TARGETS_PATH" -s high,critical -silent -o "$TMPFILE"
  NUC_EXIT="$?"
fi
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
  log "Fallback notify failed (exit $NOTIFY_EXIT). Keeping $TMPFILE for investigation: $TMPFILE"
  exit 0
fi
