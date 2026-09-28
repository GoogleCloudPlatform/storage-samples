#!/usr/bin/env bash
#
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# send-test-events.sh
#
# Writes two synthetic Service Health log entries (clearly titled
# "TEST - NOT A REAL INCIDENT") to a project so you can check that the
# Managed Lustre alert policies fire:
#   * a Managed Lustre incident in the zone's region  -> Lustre alert
#   * a Persistent Disk incident in the zone          -> dependency alert
#
# Usage:
#   ./send-test-events.sh [-n] [-o lustre|dependency] PROJECT_ID ZONE
#
#   ZONE  A zone where you run Managed Lustre, e.g. us-east4-a.
#   -o    Send only one of the two entries.
#   -n    Dry run: print the request body without sending it.
#
# Each run uses new event IDs and timestamps. Wait at least 5 minutes between
# runs (the policies rate-limit notifications to one per 5 minutes).
#
# Requirements: gcloud, curl, python3. IAM: roles/logging.logWriter.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${TEMPLATE:-${SCRIPT_DIR}/../test/test-psh-lustre-log-entry.json}"

DRY_RUN=0
ONLY=""
while getopts "no:h" opt; do
  case "${opt}" in
    n) DRY_RUN=1 ;;
    o) ONLY="${OPTARG}" ;;
    *) sed -n '17,35p' "$0"; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

PROJECT="${1:?PROJECT_ID is required}"
ZONE="${2:?ZONE is required, e.g. us-east4-a}"
if [[ ! "${ZONE}" =~ ^[a-z]+-[a-z]+[0-9]+-[a-z]$ ]]; then
  echo "ERROR: ZONE must look like us-east4-a" >&2
  exit 1
fi
if [[ -n "${ONLY}" && "${ONLY}" != "lustre" && "${ONLY}" != "dependency" ]]; then
  echo "ERROR: -o must be 'lustre' or 'dependency'" >&2
  exit 1
fi
REGION="${ZONE%-*}"

BODY="$(python3 - "${TEMPLATE}" "${PROJECT}" "${REGION}" "${ZONE}" "${ONLY}" <<'PY'
import datetime
import json
import sys
import uuid

template, project, region, zone, only = sys.argv[1:6]
with open(template) as f:
  text = f.read()
text = (text.replace("PROJECT_ID", project)
        .replace("['REGION']", "['%s']" % region)
        .replace("['ZONE']", "['%s']" % zone))
body = json.loads(text)
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
suffix = uuid.uuid4().hex[:8]
entries = []
for entry in body["entries"]:
  is_lustre = "6NIyMyXGmDuhgEOGEy2z" in entry["jsonPayload"]["impactedProductIds"]
  if only == "lustre" and not is_lustre:
    continue
  if only == "dependency" and is_lustre:
    continue
  entry["resource"]["labels"]["event_id"] += "-" + suffix
  entry["jsonPayload"]["startTime"] = now
  entry["jsonPayload"]["updateTime"] = now
  entries.append(entry)
body["entries"] = entries
print(json.dumps(body, indent=2))
PY
)"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "${BODY}"
  exit 0
fi

curl -sSf -X POST "https://logging.googleapis.com/v2/entries:write" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  --data-binary "${BODY}"
echo
echo "Test entries written to ${PROJECT} (region ${REGION}, zone ${ZONE})."
echo "Alerts should open in Monitoring > Alerting within a few minutes."
