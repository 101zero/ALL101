#!/usr/bin/env bash
set -euo pipefail

# مسارات قابلة للّغيـر عن طريق env
TARGETS_PATH="${TARGETS_PATH:-/data/5subdomains.txt}"
PROVIDER_PATH="${PROVIDER_PATH:-/secrets/provider.yaml}"
TEMPLATES_PATH="${TEMPLATES_PATH:-/nuclei-templates}"
RESULTS_PATH="${RESULTS_PATH:-/data/results.json}"

log(){ echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }

log "START - nuclei-notify run"
log "TARGETS=$TARGETS_PATH PROVIDER=$PROVIDER_PATH TEMPLATES=$TEMPLATES_PATH"

# تحقق من وجود provider
if [ ! -f "$PROVIDER_PATH" ]; then
  log "ERROR provider file missing at $PROVIDER_PATH"
  exit 2
fi

# تحقق من targets
if [ ! -f "$TARGETS_PATH" ]; then
  log "ERROR targets file missing at $TARGETS_PATH"
  exit 2
fi

# إذا ما فيه تمبليتس، نزّل النسخة الرسمية مؤقتًا
if [ ! -d "$TEMPLATES_PATH" ] || [ -z "$(ls -A "$TEMPLATES_PATH" 2>/dev/null || true)" ]; then
  log "Downloading nuclei-templates to $TEMPLATES_PATH"
  TMPZIP="/tmp/nuclei-templates.zip"
  wget -q -O "$TMPZIP" "https://github.com/projectdiscovery/nuclei-templates/archive/refs/heads/master.zip" || log "WARN: download templates failed"
  mkdir -p "$TEMPLATES_PATH"
  unzip -o "$TMPZIP" -d /tmp || true
  if [ -d /tmp/nuclei-templates-master ]; then
    mv /tmp/nuclei-templates-master/* "$TEMPLATES_PATH"/ || true
  fi
  rm -f "$TMPZIP"
fi

# safety: run on a sample first (OPTIONAL) - comment out for full run
# head -n 500 "$TARGETS_PATH" > /tmp/sample_targets.txt && TARGETS_PATH="/tmp/sample_targets.txt"

# تحكمات أداء آمنة (قابلة للتعديل عبر env)
CONCURRENCY="${CONCURRENCY:-5}"
RATE_LIMIT="${RATE_LIMIT:-50}"   # requests per second (تغيّره لو حابب أبطأ)
TIMEOUT="${TIMEOUT:-8s}"
RETRIES="${RETRIES:-0}"

log "Running nuclei with c=$CONCURRENCY rl=$RATE_LIMIT timeout=$TIMEOUT"
# نشغل nuclei ونكتب الناتج مؤقتًا كـ JSON (then notify)
TMP_OUTPUT="/tmp/nuclei_out.json"
nuclei -l "$TARGETS_PATH" -t "$TEMPLATES_PATH" -s high,critical -silent -c "$CONCURRENCY" -rl "$RATE_LIMIT" -timeout "$TIMEOUT" -retries "$RETRIES" -json -o "$TMP_OUTPUT" || log "nuclei completed (exit nonzero or no findings)"

# لو الملف فاضي نتوقف بهدوء
if [ ! -s "$TMP_OUTPUT" ]; then
  log "No findings - nothing to notify"
  echo "{}" > "$RESULTS_PATH"
  exit 0
fi

# أرسل notifications عبر notify
log "Sending notify..."
# بعض نسخ notify تأخذ -input بدل stdin; نستخدم ملف ثابت للتماشي
notify -pc "$PROVIDER_PATH" -input "$TMP_OUTPUT" || log "notify command failed"

# حفظ نسخة من النتائج
cp "$TMP_OUTPUT" "$RESULTS_PATH" || true
log "Saved results to $RESULTS_PATH"
log "FINISH"
exit 0
