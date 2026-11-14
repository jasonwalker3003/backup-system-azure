#!/usr/bin/env bash
# Nightly backup: sync each folder to its container, then write a heartbeat report.
# The missed-backup alert fires if no heartbeat arrives, so the report is only written on success.
set -uo pipefail
source "$HOME/.backup-agent.env"

ACCOUNT_URL="https://${BACKUP_ACCOUNT}.blob.core.windows.net"
RUN_ID=$(date -u +%Y-%m-%dT%H-%M-%SZ)
LOG_DIR="$HOME/backup-logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$RUN_ID.log"

# Stand-in for the firm's nightly database export.
echo "-- nightly export $(date +%F)" > "$BACKUP_SOURCE/database/clients-$(date +%F).sql"

status="success"
total=0
for folder in documents photos database; do
  out=$(azcopy sync "$BACKUP_SOURCE/$folder" "$ACCOUNT_URL/$folder" --delete-destination=false 2>&1)
  rc=$?
  echo "$out" >> "$LOG"
  copied=$(echo "$out" | grep -oP 'Number of Copy Transfers Completed: \K[0-9]+' | tail -1)
  total=$((total + ${copied:-0}))
  if [ "$rc" -ne 0 ]; then
    status="failed"
    echo "$(date -u) $folder FAILED (exit $rc)" | tee -a "$LOG"
  fi
done

report="$LOG_DIR/$RUN_ID.json"
jq -n --arg run "$RUN_ID" --arg host "$(hostname)" --arg status "$status" --argjson files "$total" \
  '{run:$run, host:$host, status:$status, files_uploaded:$files}' > "$report"

if [ "$status" = "success" ]; then
  azcopy copy "$report" "$ACCOUNT_URL/reports/$RUN_ID.json" --output-level quiet >> "$LOG" 2>&1
  echo "Backup succeeded: $total file(s) uploaded (run $RUN_ID)"
else
  echo "Backup FAILED (run $RUN_ID). No heartbeat written, so the alert will fire. Log: $LOG"
  exit 1
fi
