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

# remove-lustre-psh-alerts.sh
#
# Deletes the alert policies created by setup-lustre-psh-alerts.sh (display
# names starting with "[PSH] Managed Lustre") and, with -e, the email
# notification channel it created. Does not disable the Service Health API.
#
# Usage:
#   ./remove-lustre-psh-alerts.sh [-e EMAIL] [-n] PROJECT_ID...
#
#   -e EMAIL  Also delete the "Managed Lustre service health - EMAIL" channel.
#   -n        Dry run: list what would be deleted.
#
# Requirements: gcloud (beta component).

set -euo pipefail

EMAIL=""
DRY_RUN=0
while getopts "e:nh" opt; do
  case "${opt}" in
    e) EMAIL="${OPTARG}" ;;
    n) DRY_RUN=1 ;;
    *) sed -n '17,29p' "$0"; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
if [[ $# -lt 1 ]]; then sed -n '17,29p' "$0"; exit 1; fi

delete() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "DRY RUN: would delete $2"
  else
    echo "Deleting $2"
    gcloud $1 delete "$2" --project="${PROJECT}" --quiet
  fi
}

for PROJECT in "$@"; do
  echo "=== ${PROJECT}"
  POLICIES="$(gcloud monitoring policies list --project="${PROJECT}" \
    --filter='displayName:"[PSH] Managed Lustre"' --format="value(name)")"
  for POLICY in ${POLICIES}; do
    delete "monitoring policies" "${POLICY}"
  done

  if [[ -n "${EMAIL}" ]]; then
    CHANNELS="$(gcloud beta monitoring channels list --project="${PROJECT}" \
      --filter="displayName=\"Managed Lustre service health - ${EMAIL}\"" \
      --format="value(name)")"
    for CHANNEL in ${CHANNELS}; do
      delete "beta monitoring channels" "${CHANNEL}"
    done
  fi
done
