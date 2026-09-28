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

# list-lustre-psh-events.sh
#
# Lists ACTIVE Personalized Service Health incidents that involve Google Cloud
# Managed Lustre or the products it depends on (Persistent Disk, Compute
# Engine, VPC). Handy for runbooks, dashboards and ticket automation.
#
# Usage:
#   ./list-lustre-psh-events.sh PROJECT_ID
#   ./list-lustre-psh-events.sh -o ORGANIZATION_ID QUOTA_PROJECT_ID
#
# Project mode needs roles/servicehealth.viewer on the project.
# Organization mode needs roles/servicehealth.viewer granted on the
# organization, plus serviceusage.services.use (for example
# roles/serviceusage.serviceUsageConsumer) on QUOTA_PROJECT_ID. It only covers
# projects that have the Service Health API enabled.
#
# Requirements: gcloud, curl, jq.

set -euo pipefail

# Managed Lustre | Persistent Disk | Compute Engine | VPC
PRODUCT_IDS="${PRODUCT_IDS:-6NIyMyXGmDuhgEOGEy2z|SzESm2Ux129pjDGKWD68|L3ggmi3Jy4xJmgodFA9K|BSGtCUnz6ZmyajsjgTKv}"

ORG=""
while getopts "o:h" opt; do
  case "${opt}" in
    o) ORG="${OPTARG}" ;;
    *) sed -n '17,33p' "$0"; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
PROJECT="${1:?PROJECT_ID (or quota project for -o) is required}"

HEADERS=(-H "Authorization: Bearer $(gcloud auth print-access-token)")
if [[ -n "${ORG}" ]]; then
  URL="https://servicehealth.googleapis.com/v1/organizations/${ORG}/locations/global/organizationEvents"
  HEADERS+=(-H "x-goog-user-project: ${PROJECT}")
else
  URL="https://servicehealth.googleapis.com/v1/projects/${PROJECT}/locations/global/events"
fi

PAGE_TOKEN=""
while :; do
  PARAMS=(--data-urlencode "filter=state=ACTIVE category=INCIDENT")
  if [[ -n "${PAGE_TOKEN}" ]]; then
    PARAMS+=(--data-urlencode "pageToken=${PAGE_TOKEN}")
  fi
  RESPONSE="$(curl -sSfG "${URL}" "${HEADERS[@]}" "${PARAMS[@]}")"

  jq --arg ids "${PRODUCT_IDS}" '
    (.events // .organizationEvents // .organization_events // [])[]
    | select([.eventImpacts[]?.product.id] | any(test($ids)))
    | {
        name,
        title,
        relevance,
        detailedCategory,
        detailedState,
        updateTime,
        products: ([.eventImpacts[]?.product.productName] | unique),
        locations: ([.eventImpacts[]?.location.locationName] | unique)
      }' <<<"${RESPONSE}"

  PAGE_TOKEN="$(jq -r '.nextPageToken // empty' <<<"${RESPONSE}")"
  if [[ -z "${PAGE_TOKEN}" ]]; then break; fi
done
