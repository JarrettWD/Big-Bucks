#!/usr/bin/env bash
# The Backup workflow's commit job runs this on the backup handed over by the take
# job, before anything is committed with the write token (Stage 5, Guard 2). The take
# job runs third-party code (npm packages, pg_dump); this job runs none of it, and only
# lets through what a backup is made of:
#   schema.sql  data.sql  auth.sql  counts.json  balances.csv  manifest.json
#   csv/<schema>.<table>.csv
# Anything else (another file or folder, a link, a name with a slash or "..") stops
# the run, so nothing outside backup/ can ever be committed by it.
#
#   scripts/check-incoming.sh <folder>
set -euo pipefail

dir="${1:?Usage: check-incoming.sh <folder>}"
[ -d "$dir" ] || { echo "::error::No backup was handed over ($dir is missing)."; exit 1; }

problems=0
refuse() {
  echo "::error::The backup handed over isn't a plain backup: $1. Nothing was committed: stop and ask."
  problems=$((problems + 1))
}

# Nothing but regular files and the csv folder: no links, no devices, no other folders.
while IFS= read -r -d '' p; do
  rel="${p#"$dir"/}"
  if [ -L "$p" ]; then refuse "a link ($rel)"; continue; fi
  if [ -d "$p" ]; then
    [ "$rel" = "csv" ] || refuse "a folder ($rel)"
    continue
  fi
  [ -f "$p" ] || { refuse "something that isn't a file ($rel)"; continue; }
  case "$rel" in
    schema.sql | data.sql | auth.sql | counts.json | balances.csv | manifest.json) ;;
    csv/*)
      name="${rel#csv/}"
      [[ "$name" =~ ^(public|private)\.[a-z_][a-z0-9_]*\.csv$ ]] || refuse "an unexpected file ($rel)"
      ;;
    *) refuse "an unexpected file ($rel)" ;;
  esac
done < <(find "$dir" -mindepth 1 -print0)

for f in schema.sql data.sql auth.sql counts.json balances.csv manifest.json; do
  [ -s "$dir/$f" ] || refuse "no $f, or an empty one"
done

[ "$problems" -eq 0 ] || exit 1
echo "The backup handed over holds only backup files ($(find "$dir" -type f | wc -l) files)."
