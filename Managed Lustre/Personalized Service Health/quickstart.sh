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
#   * client projects asks whether your Lustre clients run in other projects
#   * Lustre regions found by listing your Managed Lustre instances
#   * alert email    your gcloud account
#   * permissions    checks them first and tells you which role is missing
# shows you what it will do, asks once, creates the alerts, offers to send a
# test alert, and ends with a checklist of what's in place.
#
# Usage:
#   ./quickstart.sh [-e EMAIL] [-r REGIONS] [-y] [-t | -T] [PROJECT_ID...]
#
#   -e EMAIL    Send alerts here instead of your gcloud account.
#   -r REGIONS  Comma-separated regions, if you want to set them yourself.
#   -y          Don't ask any questions (use the defaults).
#   -t / -T     Always / never send test alerts at the end.
#
# Safe to run again, for example to add a project or a region: existing
# alerts are updated, not duplicated.

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
    *) sed -n '17,38p' "$0"; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
ok() { printf '  \033[32m✔\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✘\033[0m %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

ask() {  # ask "Question" "default" -> echoes the answer
  local answer
  if [[ "${ASSUME_YES}" -eq 1 ]]; then echo "$2"; return; fi
  read -r -p "  $1 [$2]: " answer
  echo "${answer:-$2}"
}

confirm() {  # confirm "Question" -> returns 0 for yes (default yes)
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
  read -r -a PROJECTS <<<"$(ask "Project with your Managed Lustre instances" "${DEFAULT_PROJECT}")"
  [[ ${#PROJECTS[@]} -gt 0 && -n "${PROJECTS[0]}" ]] || die "no project given."

  # Incidents on Persistent Disk and Compute Engine are only delivered to
  # projects that use those products, which is usually where the clients run.
  if [[ "${ASSUME_YES}" -eq 0 ]]; then
    echo
    info "Do your Lustre clients (GPU VMs, GKE clusters) run in other projects?"
    info "Adding them means you also hear about Compute Engine and Persistent Disk"
    info "incidents that could affect Lustre."
    read -r -p "  Client project IDs, separated by spaces (Enter to skip): " CLIENTS
    for CLIENT in ${CLIENTS}; do
      [[ " ${PROJECTS[*]} " == *" ${CLIENT} "* ]] || PROJECTS+=("${CLIENT}")
    done
  fi
  echo
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
  echo
fi

# --- 5. Permissions ---------------------------------------------------------
# Check up front, so a missing role doesn't stop the setup halfway through.
bold "Checking your permissions..."
TOKEN="$(gcloud auth print-access-token 2>/dev/null || true)"
MEMBER="user:${ACCOUNT}"
[[ "${ACCOUNT}" != *.gserviceaccount.com ]] || MEMBER="serviceAccount:${ACCOUNT}"
BLOCKED=0
CAN_TEST=()   # projects where the account can write the test log entries

for PROJECT in "${PROJECTS[@]}"; do
  # Permissions needed in every project.
  NEEDED="monitoring.alertPolicies.create monitoring.alertPolicies.update monitoring.alertPolicies.list logging.logEntries.create"
  # Enabling APIs is only needed if they're off.
  ENABLED="$(gcloud services list --enabled --project="${PROJECT}" \
    --format="value(config.name)" 2>/dev/null || true)"
  for API in servicehealth.googleapis.com monitoring.googleapis.com; do
    if [[ $'\n'"${ENABLED}"$'\n' != *$'\n'"${API}"$'\n'* ]]; then
      NEEDED+=" serviceusage.services.enable"
      break
    fi
  done
  # Creating a channel is only needed if there isn't one for this email yet.
  if [[ -z "$(gcloud beta monitoring channels list --project="${PROJECT}" \
      --filter="type=\"email\" AND labels.email_address=\"${EMAIL}\"" \
      --format="value(name)" --limit=1 2>/dev/null || true)" ]]; then
    NEEDED+=" monitoring.notificationChannels.create"
  fi

  RESULT="$(python3 - "${PROJECT}" "${TOKEN}" "${MEMBER}" ${NEEDED} <<'PY'
import json
import os
import sys
import urllib.request

project, token, member = sys.argv[1:4]
needed = sys.argv[4:]
ROLES = {
    "serviceusage.services.enable": (
        "roles/serviceusage.serviceUsageAdmin", "Service Usage Admin",
        "turn on the Service Health and Monitoring APIs"),
    "monitoring.alertPolicies.create": (
        "roles/monitoring.alertPolicyEditor", "Monitoring AlertPolicy Editor",
        "create the alert policies"),
    "monitoring.alertPolicies.update": (
        "roles/monitoring.alertPolicyEditor", "Monitoring AlertPolicy Editor",
        "create the alert policies"),
    "monitoring.alertPolicies.list": (
        "roles/monitoring.alertPolicyEditor", "Monitoring AlertPolicy Editor",
        "create the alert policies"),
    "monitoring.notificationChannels.create": (
        "roles/monitoring.notificationChannelEditor",
        "Monitoring NotificationChannel Editor", "create the email channel"),
    "logging.logEntries.create": (
        "roles/logging.logWriter", "Logs Writer", "send the test alert"),
}
OPTIONAL = {"logging.logEntries.create"}

endpoint = os.environ.get("CRM_ENDPOINT",
                          "https://cloudresourcemanager.googleapis.com")
url = "%s/v1/projects/%s:testIamPermissions" % (endpoint, project)
request = urllib.request.Request(
    url, data=json.dumps({"permissions": needed}).encode(),
    headers={"Authorization": "Bearer " + token,
             "Content-Type": "application/json"})
try:
  with urllib.request.urlopen(request, timeout=30) as response:
    granted = set(json.load(response).get("permissions", []))
except Exception:  # pylint: disable=broad-except
  print("UNKNOWN")
  sys.exit(0)

missing = [p for p in needed if p not in granted]
required = sorted({ROLES[p] for p in missing if p not in OPTIONAL})
optional = sorted({ROLES[p] for p in missing if p in OPTIONAL})
print("BLOCKED" if required else ("NOTEST" if optional else "OK"))
for role, title, why in required:
  print("  - %s (%s): to %s" % (title, role, why))
for role, title, why in optional:
  print("  - Optional: %s (%s): to %s" % (title, role, why))
if missing:
  print("  Ask a project owner to run:")
  for role, _, _ in required + optional:
    print("    gcloud projects add-iam-policy-binding %s --member=%s --role=%s"
          % (project, member, role))
PY
)"
  STATUS="${RESULT%%$'\n'*}"
  DETAILS=""
  [[ "${RESULT}" != *$'\n'* ]] || DETAILS="${RESULT#*$'\n'}"
  case "${STATUS}" in
    OK) ok "${PROJECT}: all set"; CAN_TEST+=("${PROJECT}") ;;
    NOTEST) ok "${PROJECT}: can set up alerts (but can't send the test alert)"
            echo "${DETAILS}" ;;
    BLOCKED) bad "${PROJECT}: missing permissions"; echo "${DETAILS}"; BLOCKED=1 ;;
    *) info "${PROJECT}: couldn't check permissions; continuing anyway."
       CAN_TEST+=("${PROJECT}") ;;
  esac
done
echo
if [[ "${BLOCKED}" -eq 1 ]]; then
  info "Setup would fail in the projects marked ✘. Ask for the roles above, then"
  info "run this again. You can also re-run with just the projects marked ✔."
  exit 1
fi

# --- 6. Confirm -------------------------------------------------------------
bold "Here's what will happen:"
info "Projects: ${PROJECTS[*]}"
info "Lustre regions: ${REGIONS} (plus global)"
info "Alerts go to: ${EMAIL}"
info "In each project: turn on the Service Health API (if it's off), create an"
info "email channel (if needed), and create 2 alert policies. If the alerts"
info "already exist, they're updated with any new regions or email."
echo
confirm "Go ahead?" || { echo "  Nothing changed."; exit 0; }
echo

# --- 7. Create the alerts ---------------------------------------------------
PSH_FROM_QUICKSTART=1 "${SCRIPT_DIR}/scripts/setup-lustre-psh-alerts.sh" -u -r "${REGIONS}" -e "${EMAIL}" "${PROJECTS[@]}"
echo

# --- 8. Optional test -------------------------------------------------------
if [[ -z "${TEST_PROJECT}" ]]; then
  TEST_PROJECT="${PROJECTS[0]}"
  TEST_ZONE="${REGIONS%%,*}-a"
fi
if [[ " ${CAN_TEST[*]:-} " != *" ${TEST_PROJECT} "* ]]; then
  if [[ "${SEND_TEST}" == "yes" ]]; then
    info "Skipping the test alert: you need Logs Writer in ${TEST_PROJECT}."
    echo
  fi
  SEND_TEST="no"
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
TEST_SENT=0
if [[ "${SEND_TEST}" == "yes" ]]; then
  # Newly created log-based alert policies take a few minutes to start
  # evaluating logs. A test entry written right away is silently missed.
  WAIT="${TEST_WAIT_SECONDS:-180}"
  info "Waiting $((WAIT / 60)) min for the new alert policies to become active..."
  while [[ "${WAIT}" -gt 0 ]]; do
    printf '\r  %3ss left ' "${WAIT}"
    sleep 10
    WAIT=$((WAIT - 10))
  done
  printf '\r              \r'
  if "${SCRIPT_DIR}/scripts/send-test-events.sh" "${TEST_PROJECT}" "${TEST_ZONE}" >/dev/null; then
    TEST_SENT=1
  else
    bad "Couldn't send the test alert. Try later: scripts/send-test-events.sh ${TEST_PROJECT} ${TEST_ZONE}"
  fi
  echo
fi

# --- 9. Checklist -----------------------------------------------------------
bold "Checklist"
ALL_OK=1
for PROJECT in "${PROJECTS[@]}"; do
  info "${PROJECT}"
  ENABLED="$(gcloud services list --enabled --project="${PROJECT}" \
    --format="value(config.name)" 2>/dev/null || true)"
  if [[ $'\n'"${ENABLED}"$'\n' == *$'\n'"servicehealth.googleapis.com"$'\n'* ]]; then
    ok "Service Health API on"
  else
    bad "Service Health API off"; ALL_OK=0
  fi
  POLICIES="$(gcloud monitoring policies list --project="${PROJECT}" \
    --filter="displayName:\"[PSH] Managed Lustre\"" --format="value(name)" 2>/dev/null || true)"
  POLICY_COUNT="$(sed '/^$/d' <<<"${POLICIES}" | wc -l | tr -d ' ')"
  if [[ "${POLICY_COUNT}" -ge 2 ]]; then
    ok "${POLICY_COUNT} alert policies"
  else
    bad "${POLICY_COUNT} of 2 alert policies"; ALL_OK=0
  fi
  if [[ -n "$(gcloud beta monitoring channels list --project="${PROJECT}" \
      --filter="type=\"email\" AND labels.email_address=\"${EMAIL}\"" \
      --format="value(name)" --limit=1 2>/dev/null || true)" ]]; then
    ok "Email alerts go to ${EMAIL}"
  else
    bad "No email channel for ${EMAIL}"; ALL_OK=0
  fi
  if [[ "${TEST_SENT}" -eq 1 && "${PROJECT}" == "${TEST_PROJECT}" ]]; then
    ok "Test alert sent: expect 2 emails from alerting-noreply@google.com in ~5 min (check Spam)"
  fi
  info "  Alerts:         https://console.cloud.google.com/monitoring/alerting?project=${PROJECT}"
  info "  Service Health: https://console.cloud.google.com/servicehealth/incidents?project=${PROJECT}"
done
echo
if [[ "${ALL_OK}" -eq 1 ]]; then
  bold "You're done. You'll get an email when Google Cloud posts an incident that may affect Managed Lustre."
else
  bold "Some steps didn't finish (✘ above). Fix them and run ./quickstart.sh again; it's safe to re-run."
fi
info "If the Service Health API was just turned on, real incidents can take up to 24 hours to show up."
info "Add Slack, PagerDuty or SMS: open an alert policy and edit its notification channels."
info "Add a project or region later: run ./quickstart.sh again."
info "Remove everything: \"${SCRIPT_DIR}/scripts/remove-lustre-psh-alerts.sh\" -e ${EMAIL} ${PROJECTS[*]}"
