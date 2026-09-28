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

# quickstart.sh
#
# One command to set up Service Health alerts for Google Cloud Managed Lustre.
# It figures out everything it can on its own:
#   * project        your current gcloud project (or the projects you pass)
#   * Lustre regions found by listing your Managed Lustre instances
#   * alert email    your gcloud account
# shows you what it will do, asks once, creates the alerts, and offers to send
# a test alert so you can see it work.
#
# Usage:
#   ./quickstart.sh [-e EMAIL] [-r REGIONS] [-y] [-t | -T] [PROJECT_ID...]
#
#   -e EMAIL    Send alerts here instead of your gcloud account.
#   -r REGIONS  Comma-separated regions, if you want to set them yourself.
#   -y          Don't ask for confirmation.
#   -t / -T     Always / never send test alerts at the end.
#
# Add the projects that run your Lustre clients (GPU VMs, GKE clusters) as
# well as the projects that hold your Lustre instances.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMAIL=""
REGIONS=""
ASSUME_YES=0
SEND_TEST=""   # "", "yes" or "no"

while getopts "e:r:ytTh" opt; do
  case "${opt}" in
    e) EMAIL="${OPTARG}" ;;
    r) REGIONS="${OPTARG}" ;;
    y) ASSUME_YES=1 ;;
    t) SEND_TEST="yes" ;;
    T) SEND_TEST="no" ;;
    *) sed -n '17,37p' "$0"; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

ask() {  # ask "Question" "default" -> echoes the answer
  local answer
  if [[ "${ASSUME_YES}" -eq 1 ]]; then echo "$2"; return; fi
  read -r -p "  $1 [$2]: " answer
  echo "${answer:-$2}"
}

confirm() {  # confirm "Question" -> returns 0 for yes
  local answer
  if [[ "${ASSUME_YES}" -eq 1 ]]; then return 0; fi
  read -r -p "  $1 [Y/n]: " answer
  [[ -z "${answer}" || "${answer}" =~ ^[Yy] ]]
}

bold "Managed Lustre: Service Health alerts quickstart"
echo

# --- 1. Tools ---------------------------------------------------------------
for tool in gcloud python3 curl; do
  command -v "${tool}" >/dev/null || die "${tool} is not installed. Tip: run this in Cloud Shell, which has everything."
done
if ! gcloud beta --help >/dev/null 2>&1; then
  die "the gcloud 'beta' component is missing. Run: gcloud components install beta"
fi
ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"
[[ -n "${ACCOUNT}" ]] || die "gcloud isn't signed in. Run: gcloud auth login"

# --- 2. Projects ------------------------------------------------------------
PROJECTS=("$@")
if [[ ${#PROJECTS[@]} -eq 0 ]]; then
  DEFAULT_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
  if [[ -z "${DEFAULT_PROJECT}" && "${ASSUME_YES}" -eq 1 ]]; then
    die "no project given and no default gcloud project set."
  fi
  read -r -a PROJECTS <<<"$(ask "Project ID(s), separated by spaces" "${DEFAULT_PROJECT}")"
fi
[[ ${#PROJECTS[@]} -gt 0 && -n "${PROJECTS[0]}" ]] || die "no project given."

# --- 3. Lustre regions (auto-detected) --------------------------------------
TEST_ZONE=""
TEST_PROJECT=""
if [[ -z "${REGIONS}" ]]; then
  bold "Looking for your Managed Lustre instances..."
  FOUND=""
  for PROJECT in "${PROJECTS[@]}"; do
    NAMES="$(gcloud lustre instances list --location=- --project="${PROJECT}" \
      --format="value(name)" 2>/dev/null || true)"
    COUNT=0
    for NAME in ${NAMES}; do
      ZONE="$(cut -d/ -f4 <<<"${NAME}")"
      FOUND+="${ZONE%-*} "
      COUNT=$((COUNT + 1))
      if [[ -z "${TEST_ZONE}" ]]; then TEST_ZONE="${ZONE}"; TEST_PROJECT="${PROJECT}"; fi
    done
    info "${PROJECT}: ${COUNT} instance(s)"
  done
  REGIONS="$(tr ' ' '\n' <<<"${FOUND}" | sed '/^$/d' | sort -u | paste -sd, -)"
  if [[ -z "${REGIONS}" ]]; then
    info "No instances found (or the Managed Lustre API isn't enabled in these projects)."
    [[ "${ASSUME_YES}" -eq 0 ]] || die "pass the regions with -r, e.g. -r us-east4"
    REGIONS="$(ask "Regions where you run Managed Lustre, comma-separated" "us-east4")"
  fi
  echo
fi
REGIONS="${REGIONS// /}"

# --- 4. Email ---------------------------------------------------------------
if [[ -z "${EMAIL}" ]]; then
  EMAIL="$(ask "Email address for alerts" "${ACCOUNT}")"
fi

# --- 5. Confirm -------------------------------------------------------------
bold "Here's what will happen:"
info "Projects: ${PROJECTS[*]}"
info "Lustre regions: ${REGIONS} (plus global)"
info "Alerts go to: ${EMAIL}"
info "In each project: enable the Service Health API, create an email"
info "notification channel, and create 2 alert policies."
echo
confirm "Go ahead?" || { echo "  Nothing changed."; exit 0; }
echo

# --- 6. Create the alerts ---------------------------------------------------
"${SCRIPT_DIR}/scripts/setup-lustre-psh-alerts.sh" -r "${REGIONS}" -e "${EMAIL}" "${PROJECTS[@]}"
echo

# --- 7. Optional test -------------------------------------------------------
if [[ -z "${TEST_PROJECT}" ]]; then
  TEST_PROJECT="${PROJECTS[0]}"
  TEST_ZONE="${REGIONS%%,*}-a"
fi
if [[ -z "${SEND_TEST}" ]]; then
  if [[ "${ASSUME_YES}" -eq 1 ]]; then
    SEND_TEST="no"
  elif confirm "Send a test alert to ${EMAIL} now? (clearly marked TEST, nothing real)"; then
    SEND_TEST="yes"
  else
    SEND_TEST="no"
  fi
fi
if [[ "${SEND_TEST}" == "yes" ]]; then
  "${SCRIPT_DIR}/scripts/send-test-events.sh" "${TEST_PROJECT}" "${TEST_ZONE}"
  echo
  info "You should get 2 emails from alerting-noreply@google.com within about 5 minutes."
fi

# --- 8. Done ----------------------------------------------------------------
echo
bold "All set!"
for PROJECT in "${PROJECTS[@]}"; do
  info "${PROJECT}:"
  info "  Alerts:         https://console.cloud.google.com/monitoring/alerting?project=${PROJECT}"
  info "  Service Health: https://console.cloud.google.com/servicehealth/incidents?project=${PROJECT}"
done
echo
info "Add Slack, PagerDuty or SMS: open the alert policy and edit its notification channels."
info "Remove everything later: \"${SCRIPT_DIR}/scripts/remove-lustre-psh-alerts.sh\" -e ${EMAIL} ${PROJECTS[*]}"
