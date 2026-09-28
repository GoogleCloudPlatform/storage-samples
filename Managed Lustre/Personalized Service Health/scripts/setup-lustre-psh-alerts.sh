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

# setup-lustre-psh-alerts.sh
#
# Creates Personalized Service Health (PSH) alert policies for Google Cloud
# Managed Lustre in one or more projects, from the JSON files in ../policies:
#   psh-alert-managed-lustre.json        any Managed Lustre incident + updates
#   psh-alert-lustre-dependencies.json   PD / Compute Engine / VPC incidents
#                                        in your Lustre regions
#
# Usage:
#   ./setup-lustre-psh-alerts.sh -r REGIONS (-e EMAIL | -c CHANNEL) [-g] [-n] PROJECT_ID...
#
#   -r REGIONS  Comma-separated Lustre regions, e.g. us-east4,asia-northeast1
#   -e EMAIL    Reuse or create an email notification channel in each project.
#   -c CHANNEL  Use an existing channel (ID or full name). One project only,
#               because notification channels are per project.
#   -g          Do not add 'global' to the dependency location filter.
#   -n          Dry run: show what would change without changing anything.
#
# Requirements: gcloud (beta component), python3.
# IAM on each project: serviceusage.serviceUsageAdmin (enable the API),
# logging.configWriter, monitoring.alertPolicyEditor,
# monitoring.notificationChannelEditor (only when creating channels),
# servicehealth.viewer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_DIR="${POLICY_DIR:-${SCRIPT_DIR}/../policies}"
TEMPLATES=("psh-alert-managed-lustre.json" "psh-alert-lustre-dependencies.json")

EMAIL=""
CHANNEL=""
REGIONS=""
INCLUDE_GLOBAL=1
DRY_RUN=0

usage() {
  sed -n '17,39p' "$0"
  exit 1
}

while getopts "r:e:c:gnh" opt; do
  case "${opt}" in
    r) REGIONS="${OPTARG}" ;;
    e) EMAIL="${OPTARG}" ;;
    c) CHANNEL="${OPTARG}" ;;
    g) INCLUDE_GLOBAL=0 ;;
    n) DRY_RUN=1 ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

if [[ $# -lt 1 ]]; then usage; fi
if [[ -z "${REGIONS}" ]]; then
  echo "ERROR: -r REGIONS is required." >&2
  exit 1
fi
if [[ ! "${REGIONS}" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]]; then
  echo "ERROR: -r must be comma-separated region names, e.g. us-east4,asia-northeast1" >&2
  exit 1
fi
if [[ -z "${EMAIL}" && -z "${CHANNEL}" ]]; then
  echo "ERROR: pass -e EMAIL or -c CHANNEL." >&2
  exit 1
fi
if [[ -n "${CHANNEL}" && $# -gt 1 ]]; then
  echo "ERROR: -c works with a single project only (channels are per project). Use -e." >&2
  exit 1
fi
for TEMPLATE in "${TEMPLATES[@]}"; do
  if [[ ! -f "${POLICY_DIR}/${TEMPLATE}" ]]; then
    echo "ERROR: ${POLICY_DIR}/${TEMPLATE} not found. Set POLICY_DIR." >&2
    exit 1
  fi
done

REGION_REGEX="${REGIONS//,/|}"
if [[ "${INCLUDE_GLOBAL}" -eq 1 ]]; then
  REGION_REGEX="${REGION_REGEX}|global"
fi

run() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "DRY RUN: $*"
  else
    "$@"
  fi
}

# Rendered policy files go here. `mktemp -d` works on both Linux and macOS.
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

for PROJECT in "$@"; do
  echo "=== ${PROJECT}"
  run gcloud services enable servicehealth.googleapis.com --project="${PROJECT}"

  # Resolve the notification channel for this project.
  if [[ -n "${CHANNEL}" ]]; then
    CHANNEL_NAME="${CHANNEL}"
    if [[ "${CHANNEL_NAME}" != projects/* ]]; then
      CHANNEL_NAME="projects/${PROJECT}/notificationChannels/${CHANNEL}"
    fi
  else
    CHANNEL_NAME="$(gcloud beta monitoring channels list --project="${PROJECT}" \
      --filter="type=\"email\" AND labels.email_address=\"${EMAIL}\"" \
      --format="value(name)" --limit=1)"
    if [[ -z "${CHANNEL_NAME}" ]]; then
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "DRY RUN: would create an email channel for ${EMAIL}"
        CHANNEL_NAME="projects/${PROJECT}/notificationChannels/NEW_CHANNEL"
      else
        CHANNEL_NAME="$(gcloud beta monitoring channels create --project="${PROJECT}" \
          --display-name="Managed Lustre service health - ${EMAIL}" \
          --type=email --channel-labels=email_address="${EMAIL}" \
          --format="value(name)")"
      fi
    fi
  fi
  echo "Notification channel: ${CHANNEL_NAME}"

  for TEMPLATE in "${TEMPLATES[@]}"; do
    RENDERED="${WORK_DIR}/${PROJECT}-${TEMPLATE}"
    DISPLAY_NAME="$(python3 - "${POLICY_DIR}/${TEMPLATE}" "${RENDERED}" \
      "${CHANNEL_NAME}" "${REGION_REGEX}" <<'PY'
import json
import sys

src, dst, channel, region_regex = sys.argv[1:5]
with open(src) as f:
  policy = json.load(f)
policy["notificationChannels"] = [channel]
for condition in policy["conditions"]:
  log_condition = condition["conditionMatchedLog"]
  log_condition["filter"] = log_condition["filter"].replace(
      "REGION_REGEX", region_regex)
with open(dst, "w") as f:
  json.dump(policy, f, indent=2)
print(policy["displayName"])
PY
)"

    EXISTING="$(gcloud monitoring policies list --project="${PROJECT}" \
      --filter="displayName=\"${DISPLAY_NAME}\"" --format="value(name)")"
    if [[ -n "${EXISTING}" ]]; then
      echo "Exists, skipping: ${DISPLAY_NAME} (${EXISTING})"
    else
      echo "Creating: ${DISPLAY_NAME}"
      run gcloud monitoring policies create --project="${PROJECT}" \
        --policy-from-file="${RENDERED}"
    fi
  done
done

cat <<'EOF'

Done. Notes:
  * Service Health can take up to 24 hours to start processing events after
    the Service Health API is enabled on a project.
  * To test the alerts, run scripts/send-test-events.sh PROJECT_ID ZONE and
    check Monitoring > Alerting within a few minutes.
EOF
