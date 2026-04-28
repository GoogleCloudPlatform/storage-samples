#!/bin/bash

#Copyright 2025 Google LLC

#Licensed under the Apache License, Version 2.0 (the "License");
#you may not use this file except in compliance with the License.
#You may obtain a copy of the License at

#    https://www.apache.org/licenses/LICENSE-2.0

#Unless required by applicable law or agreed to in writing, software
#distributed under the License is distributed on an "AS IS" BASIS,
#WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#See the License for the specific language governing permissions and
#limitations under the License.

# --- Configuration File ---
CONFIG_FILE=${CONFIG_FILE:-"config.json"}

# --- Check for jq and install if not found ---
if ! command -v jq &> /dev/null; then
    echo "INFO: jq command not found. This script requires jq to parse config.json."
    if command -v apt-get &> /dev/null; then
        echo "Attempting to install jq using apt-get..."
        sudo apt-get update
        sudo apt-get install -y jq
    else
        echo "ERROR: apt-get not found. Cannot automatically install jq."
        echo "Please install jq manually for your system and re-run the script."
        exit 1
    fi

    # Verify installation
    if ! command -v jq &> /dev/null; then
        echo "ERROR: jq installation failed. Please try installing jq manually."
        exit 1
    else
        echo "INFO: jq installed successfully."
    fi
fi

# --- Helper functions to read from JSON ---
json_get() {
    local filter=$1
    jq -r "${filter}" "$CONFIG_FILE"
}

# Function to read a JSON array into a bash array
json_get_array() {
    local filter=$1
    local -a values=()
    readarray -t values < <(jq -r "${filter}[]" "$CONFIG_FILE" 2>/dev/null)
    echo "${values[@]}"
}

# --- Helper function to parse GoogleSQL-like array strings ---
_parse_gsql_array_string() {
    local input_string=$1
    if [[ -z "$input_string" || "$input_string" == "[]" ]]; then echo ""; return; fi
    local cleaned=${input_string//\'/}
    cleaned=${cleaned//\[/}
    cleaned=${cleaned//\]/}
    echo "${cleaned//,/ }"
}

# Waits for a command to execute successfully (exit code 0)
# Usage: wait_for <description> <timeout_seconds> <interval_seconds> <command_string>
wait_for() {
    local description=$1
    local timeout=$2
    local interval=$3
    local command_string=$4
    local end_time=$((SECONDS + timeout))

    echo "Waiting up to ${timeout}s for: ${description}..."
    while [[ $SECONDS -lt $end_time ]]; do
        if eval "${command_string}" > /dev/null 2>&1; then
            echo "Condition met: ${description}."
            return 0
        fi
        sleep "$interval"
    done

    echo "ERROR: Timeout reached after ${timeout}s waiting for: ${description}"
    return 1
}

# ------------------------------------------------------------------------------
# SECTION 0.1: DEPLOYMENT HELPER FUNCTIONS
# ------------------------------------------------------------------------------

setup_service_account() {
  local current_target_project_id="$1"
  local service_account_email="$2"
  local service_account_name="$3"
  local user_email="$4"
  local sa_display_name="$5"
  local -n sa_created_ref="$6"

  sa_created_ref=0

  echo "--------------------------------------------------------------------------------"
  echo " STEP 1: CREATE/VALIDATE SERVICE ACCOUNT & BASE PERMISSIONS in ${current_target_project_id}"
  echo "--------------------------------------------------------------------------------"
  gcloud config set project "${current_target_project_id}" --quiet

  echo "Checking for service account ${service_account_email} in project ${current_target_project_id}..."
  if ! gcloud iam service-accounts describe "${service_account_email}" --project="${current_target_project_id}" &> /dev/null; then
    echo "Creating service account ${service_account_name}..."
    gcloud iam service-accounts create "${service_account_name}" \
        --display-name="${sa_display_name}" \
        --project="${current_target_project_id}" --quiet
    sa_created_ref=1
    echo "Service account ${service_account_email} created."
  fi
  wait_for "service account ${service_account_email} creation to propagate" 300 5 "gcloud iam service-accounts describe '${service_account_email}' --project='${current_target_project_id}'"

  echo "Granting roles/iam.serviceAccountUser to ${user_email} on the SA in project ${current_target_project_id}..."
  gcloud iam service-accounts add-iam-policy-binding "${service_account_email}" \
    --member="user:${user_email}" \
    --role="roles/iam.serviceAccountUser" \
    --project="${current_target_project_id}" --condition=None --quiet
  wait_for "iam.serviceAccountUser role propagation for ${user_email} on SA ${service_account_email}" 300 10 "gcloud iam service-accounts get-iam-policy '${service_account_email}' --flatten='bindings' --filter='bindings.role=roles/iam.serviceAccountUser AND bindings.members:user:${user_email}' --format='value(bindings.role)' | grep -q 'roles/iam.serviceAccountUser'"

  echo "Granting SA roles/bigquery.jobUser in TARGET project ${current_target_project_id} (needed to run jobs)..."
  wait_for "Grant roles/bigquery.jobUser to SA ${service_account_email} on project" 300 15 \
      "gcloud projects add-iam-policy-binding '${current_target_project_id}' \
      --member='serviceAccount:${service_account_email}' \
      --role='roles/bigquery.jobUser' \
      --condition=None --quiet"
  echo "Service Account project-level role grant complete."
  wait_for "bigquery.jobUser role propagation for ${service_account_email} in ${current_target_project_id}" 300 10 "gcloud projects get-iam-policy '${current_target_project_id}' --flatten='bindings' --filter='bindings.role=roles/bigquery.jobUser AND bindings.members:serviceAccount:${service_account_email}' --format='value(bindings.role)' | grep -q 'roles/bigquery.jobUser'"
  echo ""
}

grant_sa_source_access() {
  local service_account_email="$1"
  local source_project_id="$2"
  shift 2
  local current_vault_projects=("$@")

  echo "--------------------------------------------------------------------------------"
  echo " STEP 2: GRANT SERVICE ACCOUNT ACCESS TO SOURCE DATA"
  echo "--------------------------------------------------------------------------------"
  echo "Granting SA ${service_account_email} roles/bigquery.dataViewer in SOURCE project ${source_project_id}..."
  gcloud projects add-iam-policy-binding "${source_project_id}" \
    --member="serviceAccount:${service_account_email}" \
    --role="roles/bigquery.dataViewer" \
    --condition=None --quiet || echo "WARN: Failed to grant dataViewer on ${source_project_id}"

  for project_id in "${current_vault_projects[@]}"; do
    project_id=$(echo "${project_id}" | xargs)
    if [ -n "${project_id}" ]; then
      echo "Granting SA ${service_account_email} roles/bigquery.dataViewer in VAULT project ${project_id}..."
      gcloud projects add-iam-policy-binding "${project_id}" \
        --member="serviceAccount:${service_account_email}" \
        --role="roles/bigquery.dataViewer" \
        --condition=None --quiet || echo "WARN: Failed to grant dataViewer on ${project_id}"
    fi
  done
  echo "Service Account source data permissions granted."
  wait_for "bigquery.dataViewer role on ${source_project_id}" 300 10 "gcloud projects get-iam-policy '${source_project_id}' --flatten='bindings' --filter='bindings.role=roles/bigquery.dataViewer AND bindings.members:serviceAccount:${service_account_email}' --format='value(bindings.role)' | grep -q 'roles/bigquery.dataViewer'"
  for project_id in "${current_vault_projects[@]}"; do
    project_id=$(echo "${project_id}" | xargs)
    if [ -n "${project_id}" ]; then
      wait_for "bigquery.dataViewer role propagation on ${project_id}" 300 10 "gcloud projects get-iam-policy '${project_id}' --flatten='bindings' --filter='bindings.role=roles/bigquery.dataViewer AND bindings.members:serviceAccount:${service_account_email}' --format='value(bindings.role)' | grep -q 'roles/bigquery.dataViewer'"
    fi
  done
  echo ""
}

create_target_dataset() {
  local current_target_project_id="$1"
  local target_dataset_id="$2"
  local target_location="$3"
  local service_account_email="$4"
  local env_suffix="$5"
  local -n dataset_created_ref="$6" # nameref for dataset_created

  dataset_created_ref=0

  echo "--------------------------------------------------------------------------------"
  echo " STEP 3: CREATE TARGET DATASET and SET PERMISSIONS in ${current_target_project_id}"
  echo "--------------------------------------------------------------------------------"
  gcloud config set project "${current_target_project_id}" --quiet

  echo "Ensuring Cloud Resource Manager API is enabled in ${current_target_project_id}..."
  gcloud services enable cloudresourcemanager.googleapis.com --project="${current_target_project_id}" --quiet
  wait_for "Cloud Resource Manager API to be enabled in ${current_target_project_id}" 300 10 "gcloud services list --enabled --filter='name:cloudresourcemanager.googleapis.com' --project='${current_target_project_id}' --format='value(name)' | grep -q ."

  echo "Checking if target dataset ${current_target_project_id}:${target_dataset_id} exists..."
  if ! bq show --quiet "${current_target_project_id}:${target_dataset_id}" &> /dev/null; then
    echo "Creating target dataset ${current_target_project_id}:${target_dataset_id}..."
    bq mk --dataset --location="${target_location}" --quiet "${current_target_project_id}:${target_dataset_id}"
    dataset_created_ref=1
    echo "Dataset ${target_dataset_id} created."
    wait_for "dataset ${current_target_project_id}:${target_dataset_id} creation" 300 5 "bq show --quiet '${current_target_project_id}:${target_dataset_id}'"
  else
    echo "Dataset ${target_dataset_id} already exists."
  fi

  TARGET_DS_ACCESS_FILE="/tmp/${target_dataset_id}_access_${env_suffix}_$$.json"
  TARGET_DS_ACCESS_FILE_UPDATED="${TARGET_DS_ACCESS_FILE}_updated"

  update_access_json() {
      local email="$1"
      local role="$2"
      local file="$3"
      local tmp_file="/tmp/jq_tmp_${env_suffix}_$$.json"
      local jq_filter='(.access | map(select(.userByEmail != $email_arg))) + [{"role": $role_arg, "userByEmail": $email_arg}]'
      if ! jq --arg email_arg "${email}" --arg role_arg "${role}" ".access = ${jq_filter}" "${file}" > "${tmp_file}"; then
          echo "ERROR: JQ command failed for ${email} with role ${role}."
          rm -f "${tmp_file}"; return 1
      fi
      mv "${tmp_file}" "${file}"
  }

  echo "--- Setting Access Controls for ${current_target_project_id}:${target_dataset_id} ---"
  if ! bq show --format=prettyjson "${current_target_project_id}:${target_dataset_id}" > "${TARGET_DS_ACCESS_FILE}"; then
      echo "ERROR: Failed to fetch dataset ACL for ${target_dataset_id}. Exiting."
      return 1
  fi
  cp "${TARGET_DS_ACCESS_FILE}" "${TARGET_DS_ACCESS_FILE_UPDATED}"

  echo "Setting role WRITER for SA ${service_account_email}"
  update_access_json "${service_account_email}" "WRITER" "${TARGET_DS_ACCESS_FILE_UPDATED}" || return 1

  PROJECT_OWNERS_FILTER='.access += [{"role": "OWNER", "specialGroup": "projectOwners"}]'
  if ! jq "$PROJECT_OWNERS_FILTER" "${TARGET_DS_ACCESS_FILE_UPDATED}" > "${TARGET_DS_ACCESS_FILE}_tmp"; then
      echo "ERROR: Failed to add projectOwners"; return 1
  fi
  mv "${TARGET_DS_ACCESS_FILE}_tmp" "${TARGET_DS_ACCESS_FILE_UPDATED}"
  jq '.access |= unique_by(.userByEmail // .specialGroup)' "${TARGET_DS_ACCESS_FILE_UPDATED}" > "${TARGET_DS_ACCESS_FILE}_tmp" && mv "${TARGET_DS_ACCESS_FILE}_tmp" "${TARGET_DS_ACCESS_FILE_UPDATED}"

  echo "Attempting to update dataset ACL for ${current_target_project_id}:${target_dataset_id}..."
  if bq update --source "${TARGET_DS_ACCESS_FILE_UPDATED}" "${current_target_project_id}:${target_dataset_id}"; then
      echo "SUCCESS: Dataset ${target_dataset_id} access controls updated."
  else
      echo "ERROR: Failed to update dataset access controls for ${target_dataset_id}."
      return 1
  fi
  rm -f "${TARGET_DS_ACCESS_FILE}" "${TARGET_DS_ACCESS_FILE_UPDATED}"
  wait_for "WRITER role for ${service_account_email} on dataset ${target_dataset_id}" 300 10 "bq show --format=prettyjson '${current_target_project_id}:${target_dataset_id}' | jq -e --arg SA_EMAIL '${service_account_email}' '.access[] | select(.userByEmail == \$SA_EMAIL and .role == \"WRITER\")'"
  echo ""
}

# --- Function to generate the DTS SQL query ---
_get_dts_query() {
  local current_target_project_id="$1"
  shift
  local dts_vault_projects=("$@") # Projects for LOG UNION

  local run_date_expression="@run_date"
  if [[ -n "${SQL_TEST_RUN_DATE}" ]]; then
    run_date_expression="DATE '${SQL_TEST_RUN_DATE}'"
  fi
  local log_suffix_filter="_TABLE_SUFFIX = FORMAT_DATE('%Y%m%d', DATE_SUB(${run_date_expression}, INTERVAL 2 DAY))"

  # --- Construct the Parameterized SQL Query for DTS ---
  LOG_UNION_SQL=""
  for project_id in "${dts_vault_projects[@]}"; do
    project_id=$(echo "${project_id}" | xargs)
    if [ -z "${project_id}" ]; then continue; fi

    local log_table
    if [[ -n "${SQL_TEST_TABLE_OVERRIDE}" ]]; then
      log_table="\`${SQL_TEST_LOG_PROJECT_OVERRIDE}.${LOGS_DATASET}.bdr_details_${project_id//-/_}_*\`"
    else
      log_table="\`${project_id}.${LOGS_DATASET}.backupdr_googleapis_com_bdr_backup_vault_details_*\`"
    fi

    CURRENT_LOG_SQL=$(cat <<EOF
            SELECT
            t.jsonpayload_v1_bdrbackupvaultdetailslog.backupvaultname AS bVName,
            t.jsonpayload_v1_bdrbackupvaultdetailslog.minimumenforcedretentiondays AS retentionDays,
            t.jsonpayload_v1_bdrbackupvaultdetailslog.sourceresourcelocation AS resourceLocation,
            t.jsonpayload_v1_bdrbackupvaultdetailslog.sourceresourcename AS resourceName,
            t.jsonpayload_v1_bdrbackupvaultdetailslog.currentbackupplanname AS BackupPlanName,
            t.jsonpayload_v1_bdrbackupvaultdetailslog.resourcetype AS resorceType,
            t.jsonpayload_v1_bdrbackupvaultdetailslog.backupVaultType AS backupVaultType,
            ARRAY_LAST(SPLIT(t.jsonpayload_v1_bdrbackupvaultdetailslog.sourceresourcename, '/')) AS instanceName,
            t.resource.labels.location AS logLocation,
            t.receiveTimestamp AS ReceiveTimestamp,
            t.jsonpayload_v1_bdrbackupvaultdetailslog.workloaduniqueid AS ResourceID,
            REGEXP_EXTRACT(t.jsonpayload_v1_bdrbackupvaultdetailslog.backupvaultname, r'locations/([^/]+)') AS backupVaultLocation,
            REGEXP_EXTRACT(t.jsonpayload_v1_bdrbackupvaultdetailslog.sourceresourcename, r'projects/([^/]+)') AS sourceProject,
            t.receiveTimestamp AS received_date,
            '${project_id}' AS project_id
            FROM ${log_table} AS t
            WHERE ${log_suffix_filter}
EOF
  )
    if [ -z "${LOG_UNION_SQL}" ]; then LOG_UNION_SQL="${CURRENT_LOG_SQL}"; else LOG_UNION_SQL="${LOG_UNION_SQL}
            UNION ALL
  ${CURRENT_LOG_SQL}"; fi
  done

  local billing_table="\`${SOURCE_PROJECT_ID}.${BILLING_DATASET}.gcp_billing_export_resource_v1_${BILLING_ACCOUNT_ID//-/_}\`"
  if [[ -n "${SQL_TEST_BILLING_TABLE}" ]]; then
    billing_table="${SQL_TEST_BILLING_TABLE}"
  fi

  PROJECT_FILTER=""
  if [[ -z "${TARGET_PROJECT_ID}" ]]; then
    PROJECT_FILTER=" AND project.id IN (SELECT DISTINCT sourceProject FROM LogData WHERE sourceProject IS NOT NULL UNION DISTINCT SELECT '${current_target_project_id}')"
  fi

  cat << EOF
WITH LogRawData AS (
  SELECT
        bVName, retentionDays, resourceLocation, resourceName, BackupPlanName, resorceType, backupVaultType, instanceName, logLocation, ReceiveTimestamp, ResourceID,
        backupVaultLocation, sourceProject, received_date, project_id,
         ROW_NUMBER() OVER (PARTITION BY ResourceID, DATE(received_date, '${TIMEZONE}') ORDER BY ReceiveTimestamp DESC) AS rn
  FROM ( ${LOG_UNION_SQL} )
),
LogData AS ( SELECT *, DATE(received_date, '${TIMEZONE}') AS LogDate FROM LogRawData WHERE rn = 1 ),
BillingData_Raw AS (
    SELECT
        sku,
        service,
        location,
        usage,
        system_labels,
        project,
        currency,
        cost,
        IFNULL((SELECT SUM(CAST(c.amount AS NUMERIC)) FROM UNNEST(credits) c), 0) AS credit,
        DATE(TIMESTAMP_TRUNC(usage_start_time, DAY, '${TIMEZONE}')) AS BillingDate
    FROM ${billing_table}
    WHERE
        service.id IN ('${BACKUPDR_SERVICE_ID}') -- Filter for the BackupDR service only
        AND sku.description LIKE 'BackupDR%' -- Filter for BackupDR specific SKUs
        AND sku.id NOT IN (${EXCLUDED_SKUS})
        AND usage_start_time >= TIMESTAMP(DATE_SUB(${run_date_expression}, INTERVAL 2 DAY), '${TIMEZONE}')
        AND usage_start_time < TIMESTAMP(DATE_SUB(${run_date_expression}, INTERVAL 1 DAY), '${TIMEZONE}')
        AND (SELECT l.value FROM UNNEST(system_labels) l WHERE l.key = 'backupdr.googleapis.com/workload_unique_id') IS NOT NULL
        AND (SELECT l.value FROM UNNEST(system_labels) l WHERE l.key = 'backupdr.googleapis.com/workload_unique_id') != ''
        ${PROJECT_FILTER}
),
BillingData_Aggregated AS (
    SELECT
        sku.description AS \`SKU Description\`, service.description AS \`Service Description\`, sku.id AS \`SKU ID\`, location.location AS \`LOCATION\`,
        (SELECT l.value FROM UNNEST(system_labels) l WHERE l.key = 'backupdr.googleapis.com/workload_unique_id') AS UniqueId,
        BillingDate, project.id AS ProjectID,
        ANY_VALUE(currency) AS Currency,
        SUM(usage.amount_in_pricing_units) AS \`Usage in Pricing Units\`, ANY_VALUE(usage.pricing_unit) AS \`Usage Pricing Unit\`,
        SUM(cost) AS \`Gross Cost\`,
        SUM(IFNULL(credit, 0)) AS \`Credits\`,
        SUM(CAST(cost AS NUMERIC) + IFNULL(credit, 0)) AS \`Net Cost\`
    FROM BillingData_Raw
    GROUP BY 1, 2, 3, 4, 5, 6, 7
)
SELECT
  b.BillingDate AS \`report_date\`,l.resourceName AS \`resource_name\`,l.resorceType AS \`resource_type\`, l.backupVaultType AS \`backup_vault_type\`, l.instanceName AS \`resource\`, b.\`LOCATION\` AS \`billing_location\`,
  b.\`Usage in Pricing Units\` AS \`usage_in_pricing_units\`, b.\`Usage Pricing Unit\` AS \`usage_pricing_unit\`,
  b.\`Gross Cost\` AS \`cost\`,
  b.Currency AS \`currency\`,
  b.\`Credits\` AS \`credits\`,
  b.\`Net Cost\` AS \`net_cost\`,
  b.\`SKU Description\` AS sku_description, b.\`SKU ID\` AS sku_id,
  l.bVName AS backup_vault_name, l.resourceLocation AS resource_location, l.BackupPlanName AS backup_plan_name, l.backupVaultLocation AS backup_vault_location, l.sourceProject AS source_project
FROM BillingData_Aggregated b
JOIN LogData l ON b.UniqueId = l.ResourceID AND b.BillingDate = l.LogDate
WHERE b.BillingDate = DATE_SUB(${run_date_expression}, INTERVAL 2 DAY);
EOF
}

create_bigquery_dts() {
  local current_target_project_id="$1"
  local service_account_email="$2"
  local dts_target_table_template="$3"
  local env_suffix="$4"
  local -n dts_config_resource_name_ref="$5"
  shift 5
  local current_vault_projects=("$@") # Projects for LOG UNION

  dts_config_resource_name_ref=""

  echo "--------------------------------------------------------------------------------"
  echo " STEP 4: CREATE/UPDATE BIGQUERY DATA TRANSFER & TRIGGER BACKFILL in ${current_target_project_id}"
  echo "--------------------------------------------------------------------------------"
  gcloud config set project "${current_target_project_id}" --quiet
  echo "Enabling BigQuery Data Transfer API in ${current_target_project_id}..."
  gcloud services enable bigquerydatatransfer.googleapis.com --project="${current_target_project_id}" --quiet
  wait_for "BigQuery Data Transfer API to be enabled in ${current_target_project_id}" 300 10 "gcloud services list --enabled --filter='name:bigquerydatatransfer.googleapis.com' --project='${current_target_project_id}' --format='value(name)' | grep -q ."

  DTS_SERVICE_AGENT=$(gcloud beta services identity create \
      --service=bigquerydatatransfer.googleapis.com \
      --project="${current_target_project_id}" \
      --format="value(email)" \
      --quiet)

  # Grant Service Agent Role
  echo "Granting 'roles/bigquerydatatransfer.serviceAgent'..."
  wait_for "Service Agent Role Assignment" 180 10 \
    "gcloud projects add-iam-policy-binding '${current_target_project_id}' \
    --member='serviceAccount:${DTS_SERVICE_AGENT}' \
    --role='roles/bigquerydatatransfer.serviceAgent' \
    --condition=None \
    --quiet"

  # Grant Token Creator Role
  echo "Granting 'roles/iam.serviceAccountTokenCreator'."
  wait_for "Token Creator Role Assignment" 180 10 \
    "gcloud iam service-accounts add-iam-policy-binding '${service_account_email}' \
    --member='serviceAccount:${DTS_SERVICE_AGENT}' \
    --role='roles/iam.serviceAccountTokenCreator' \
    --condition=None \
    --quiet"

  echo "Verifying IAM policy propagation..."
  wait_for "TokenCreator role visibility" 300 5 \
    "gcloud iam service-accounts get-iam-policy '${service_account_email}' \
    --flatten='bindings' \
    --filter='bindings.role=roles/iam.serviceAccountTokenCreator AND bindings.members:serviceAccount:${DTS_SERVICE_AGENT}' \
    --format='value(bindings.role)' \
    | grep -q 'roles/iam.serviceAccountTokenCreator'"

  echo "--- SERVICE AGENT CONFIGURATION COMPLETE ---"

  DTS_QUERY=$(_get_dts_query "${current_target_project_id}" "${current_vault_projects[@]}")
  ESCAPED_DTS_QUERY=$(echo "${DTS_QUERY}" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
  DTS_TARGET_TABLE_TEMPLATE_ESCAPED=$(echo "${dts_target_table_template}" | sed 's/"/\\"/g')
  PARAMS_JSON=$(cat <<EOF | tr -d '\n'
{
  "query": "${ESCAPED_DTS_QUERY}",
  "destination_table_name_template": "${DTS_TARGET_TABLE_TEMPLATE_ESCAPED}",
  "write_disposition": "${DTS_WRITE_DISPOSITION}"
}
EOF
)

  echo "Checking for existing Transfer Configs with display name: ${DTS_DISPLAY_NAME} in location ${TARGET_LOCATION}"
  set +e
  EXISTING_TRANSFER_CONFIGS_JSON=$(bq ls --transfer_config --project_id="${current_target_project_id}" --format=json --transfer_location="${TARGET_LOCATION}" 2>&1)
  BQ_LS_EXIT_CODE=$?
  set -e
  if [ ${BQ_LS_EXIT_CODE} -ne 0 ]; then
    echo "Warning: bq ls to find existing transfer configs returned non-zero exit code ${BQ_LS_EXIT_CODE}."
    EXISTING_TRANSFER_CONFIGS_JSON="[]"
  fi

  if [ -n "${EXISTING_TRANSFER_CONFIGS_JSON}" ] && [ "${EXISTING_TRANSFER_CONFIGS_JSON}" != "[]" ] && [ "${EXISTING_TRANSFER_CONFIGS_JSON}" != "{}" ]; then
      set +e
      EXISTING_CONFIG_NAMES=$(echo "${EXISTING_TRANSFER_CONFIGS_JSON}" | jq -r --arg DN "${DTS_DISPLAY_NAME}" '.[] | select(.displayName == $DN) | .name')
      set -e
      if [ -n "${EXISTING_CONFIG_NAMES}" ]; then
          echo "${EXISTING_CONFIG_NAMES}" | while read -r config_name; do
              if [ -n "$config_name" ]; then
                  echo "Deleting existing config: ${config_name}"
                  set +e
                  bq rm --transfer_config --force --quiet "${config_name}"
                  DELETE_EXIT_CODE=$?
                  set -e
                  if [ ${DELETE_EXIT_CODE} -ne 0 ]; then
                      echo "WARN: Failed to delete ${config_name} (Exit Code: ${DELETE_EXIT_CODE})";
                  fi
              fi
          done
          wait_for "all DTS configs named '${DTS_DISPLAY_NAME}' to be deleted" 120 10 "bq ls --transfer_config --project_id='${current_target_project_id}' --transfer_location='${TARGET_LOCATION}' --format=json 2>/dev/null | jq -e --arg DN '${DTS_DISPLAY_NAME}' '(map(select(.displayName == \$DN)) | length) == 0' > /dev/null"
      fi
  fi

  echo "Creating BigQuery Transfer Config: ${DTS_DISPLAY_NAME}..."
  BEFORE_CREATE_TIMESTAMP=$(date -u +%s)
  set +e
  bq mk \
      --transfer_config \
      --project_id="${current_target_project_id}" \
      --data_source=scheduled_query \
      --target_dataset="${TARGET_DATASET_ID}" \
      --display_name="${DTS_DISPLAY_NAME}" \
      --params="${PARAMS_JSON}" \
      --schedule="${DTS_SCHEDULE}" \
      --service_account_name="${service_account_email}" \
      --location="${TARGET_LOCATION}" --quiet
  MK_EXIT_CODE=$?
  set -e

  if [ ${MK_EXIT_CODE} -eq 0 ]; then
    echo "BigQuery Transfer Config creation command finished for ${env_suffix}."

    RETRY_COUNT=0
    MAX_RETRIES=5
    RETRY_DELAY=15
    while [ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]; do
      echo "Attempt $((${RETRY_COUNT} + 1))/${MAX_RETRIES} to list transfer config..."
      set +e
      BQ_LS_OUTPUT=$(bq ls --transfer_config --project_id="${current_target_project_id}" --format=json --transfer_location="${TARGET_LOCATION}" 2>&1)
      LS_EXIT_CODE=$?
      set -e

      if [ ${LS_EXIT_CODE} -eq 0 ]; then
        if [ -n "${BQ_LS_OUTPUT}" ] && [ "${BQ_LS_OUTPUT}" != "[]" ] && [ "${BQ_LS_OUTPUT}" != "{}" ]; then
          set +e
          dts_config_resource_name_ref=$(echo "${BQ_LS_OUTPUT}" | jq -r --arg DN "${DTS_DISPLAY_NAME}" --arg BT "${BEFORE_CREATE_TIMESTAMP}" '
            [.[] | select(.displayName == $DN and ((.updateTime | sub("\\.\\d+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ")) > ($BT | tonumber)))] | sort_by(.updateTime) | last | .name
          ')
          JQ_EXIT_CODE=$?
          set -e

          if [ ${JQ_EXIT_CODE} -eq 0 ] && [ -n "${dts_config_resource_name_ref}" ] && [ "${dts_config_resource_name_ref}" != "null" ]; then
            echo "Successfully found newly created Transfer Config: ${dts_config_resource_name_ref}"
            break
          else
            dts_config_resource_name_ref=""
          fi
        fi
      fi
      RETRY_COUNT=$((${RETRY_COUNT} + 1))
      if [ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]; then
        local delay=$((RETRY_DELAY * (2 ** (RETRY_COUNT - 1) )))
        sleep ${delay}
      fi
    done

    if [ -n "${dts_config_resource_name_ref}" ]; then
      if [[ "${BACKFILL_DAYS}" -gt 0 ]]; then
        BACKFILL_END_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        BACKFILL_START_DATE=$(date -u -d "${BACKFILL_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ)

        echo "Triggering backfill for the last ${BACKFILL_DAYS} days (${BACKFILL_START_DATE} to ${BACKFILL_END_DATE})..."
        set +e
        bq mk --transfer_run --start_time "${BACKFILL_START_DATE}" --end_time "${BACKFILL_END_DATE}" "${dts_config_resource_name_ref}"
        BACKFILL_EXIT_CODE=$?
        set -e

        if [ ${BACKFILL_EXIT_CODE} -eq 0 ]; then
          echo "SUCCESS: Backfill for ${BACKFILL_DAYS} days has been scheduled."
        else
          echo "ERROR: Failed to trigger backfill (Exit Code: ${BACKFILL_EXIT_CODE}). Please check the DTS console."
          return 1
        fi
      else
        echo "BACKFILL_DAYS is set to ${BACKFILL_DAYS}, skipping automatic backfill."
      fi
    else
      echo "ERROR: Failed to retrieve the NEWLY created Transfer Config resource name after ${MAX_RETRIES} attempts."
      return 1
    fi
  else
    echo "Error creating BigQuery Transfer Config for ${env_suffix} (Exit Code: ${MK_EXIT_CODE}). Check logs above."
    return 1
  fi
  echo ""
}

# ------------------------------------------------------------------------------
# SECTION 0.2: CORE DEPLOYMENT FUNCTION
# ------------------------------------------------------------------------------
deploy_billing_report() {
  local current_target_project_id="$1"
  local current_vault_projects_array_str="$2"

  export SERVICE_ACCOUNT_EMAIL="${SA_PREFIX}@${current_target_project_id}.iam.gserviceaccount.com"
  export SERVICE_ACCOUNT_NAME=$(echo "${SERVICE_ACCOUNT_EMAIL}" | cut -d'@' -f1)

  # Flags to track resource creation for cleanup
  local sa_created=0
  local dataset_created=0
  local dts_config_resource_name=""

  # --- Cleanup Function ---
  cleanup_on_error() {
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "ERROR: Deployment failed for ${current_target_project_id}. Initiating cleanup..."
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    trap - ERR # Remove the trap to avoid recursion

    gcloud config set project "${current_target_project_id}" --quiet

    if [[ -n "${dts_config_resource_name}" ]]; then
      echo "Cleaning up DTS Config: ${dts_config_resource_name}"
      bq rm --transfer_config --force --quiet "${dts_config_resource_name}" || echo "WARN: Failed to delete DTS Config ${dts_config_resource_name} (may not exist)."
    fi

    if [[ "${dataset_created}" -eq 1 ]]; then
      echo "Cleaning up Dataset: ${current_target_project_id}:${TARGET_DATASET_ID}"
      bq rm -r -f --quiet --dataset "${current_target_project_id}:${TARGET_DATASET_ID}" || echo "WARN: Failed to delete Dataset ${TARGET_DATASET_ID} (may not exist)."
    fi

    if [[ "${sa_created}" -eq 1 ]]; then
      echo "Cleaning up Service Account: ${SERVICE_ACCOUNT_EMAIL}"
      gcloud iam service-accounts delete "${SERVICE_ACCOUNT_EMAIL}" --quiet || echo "WARN: Failed to delete Service Account ${SERVICE_ACCOUNT_EMAIL} (may not exist)."
    fi
    echo "Cleanup finished for ${current_target_project_id}."
    # Exiting the subshell, which will cause the main script to continue if called in a loop
  }

  # Set the trap for the ERR signal
  trap cleanup_on_error ERR

  CURRENT_VAULT_PROJECTS=($(_parse_gsql_array_string "${current_vault_projects_array_str}"))

  # --- Generate a unique suffix for resources ---
  # This suffix is used to create unique names for temporary files and potentially
  # other resources based on the list of vault projects.
  # It takes the array string, removes brackets and quotes, replaces commas
  # with spaces, sanitizes characters, and truncates to 30 characters.
  # Example: "['gcp-proj-a','gcp-proj-b']" becomes "gcp_proj_a_gcp_proj_b"
  # This is useful for debugging as temporary files include this suffix in their name,
  # making it easier to identify which execution created them.
  ENV_SUFFIX=$(echo "${current_vault_projects_array_str}" | sed "s/\['//g" | sed "s/'\]//g" | sed "s/'\s*,\s*'/ /g" | sed "s/[^a-zA-Z0-9_-]/_/g")
  ENV_SUFFIX=${ENV_SUFFIX:0:30}
  ENV_SUFFIX=$(echo ${ENV_SUFFIX} | sed 's/_$//')

  if [ -z "${ENV_SUFFIX}" ]; then
    echo "ERROR: Could not generate a valid ENV_SUFFIX from current_vault_projects_array_str: ${current_vault_projects_array_str}"
    return 1
  fi

  export DTS_TARGET_TABLE_TEMPLATE="${DTS_TARGET_TABLE_PREFIX}_{run_time-48h|\"%Y%m%d\"}"

  echo "================================================================================"
  echo " DEPLOYING FOR TARGET: ${current_target_project_id} with ENV SUFFIX: ${ENV_SUFFIX}"
  echo " Vault Projects for Logs: ${current_vault_projects_array_str}"
  echo " DTS Name: ${DTS_DISPLAY_NAME}"
  echo "================================================================================"

  setup_service_account "${current_target_project_id}" "${SERVICE_ACCOUNT_EMAIL}" "${SERVICE_ACCOUNT_NAME}" "${USER_EMAIL}" "${SA_DISPLAY_NAME}" sa_created
  grant_sa_source_access "${SERVICE_ACCOUNT_EMAIL}" "${SOURCE_PROJECT_ID}" "${CURRENT_VAULT_PROJECTS[@]}"
  create_target_dataset "${current_target_project_id}" "${TARGET_DATASET_ID}" "${TARGET_LOCATION}" "${SERVICE_ACCOUNT_EMAIL}" "${ENV_SUFFIX}" dataset_created
  echo "Waiting 60s for IAM permissions to propagate to BigQuery DTS..."
  sleep 60
  create_bigquery_dts "${current_target_project_id}" "${SERVICE_ACCOUNT_EMAIL}" "${DTS_TARGET_TABLE_TEMPLATE}" "${ENV_SUFFIX}" dts_config_resource_name "${CURRENT_VAULT_PROJECTS[@]}"

  # Disable the trap if everything succeeded
  trap - ERR
  echo "Deployment function completed successfully for ${current_target_project_id}."
  return 0
}

run_main() {
COST_REPORT_VERSION="0.1"
echo "BackupDR Cost Report Deployment Script Version: ${COST_REPORT_VERSION}"

set -eE
# set -x # Uncomment for detailed debugging

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: Configuration file not found: $CONFIG_FILE"
  exit 1
fi

# --- Hardcoded Configuration ---
export SOURCE_LOCATION=${SOURCE_LOCATION:-"us"}
export TARGET_LOCATION=${TARGET_LOCATION:-"us"}
export BACKUPDR_SERVICE_ID=${BACKUPDR_SERVICE_ID:-"3DAD-299B-0D94"}
export EXCLUDED_SKUS=${EXCLUDED_SKUS:-"'BA82-13B3-AEA2', 'DE73-152C-OC95'"}
export TARGET_DATASET_ID=${TARGET_DATASET_ID:-"BackupDr_Billing_Reports"}
export TIMEZONE=${TIMEZONE:-"America/Los_Angeles"}
export BACKFILL_DAYS=${BACKFILL_DAYS:-30}
export DTS_DISPLAY_NAME=${DTS_DISPLAY_NAME:-"Daily BackupDR Billing Report"}
export DTS_TARGET_TABLE_PREFIX=${DTS_TARGET_TABLE_PREFIX:-"BackupDr_Billing_Report"}
export DTS_SCHEDULE=${DTS_SCHEDULE:-"every 24 hours"}
export DTS_WRITE_DISPOSITION=${DTS_WRITE_DISPOSITION:-"WRITE_TRUNCATE"}
export SA_PREFIX=${SA_PREFIX:-"dts-report"}
export SA_DISPLAY_NAME=${SA_DISPLAY_NAME:-"DTS Runner for Billing Reports"}

# --- Load Configuration from JSON ---

# GCP Settings
export TARGET_PROJECT_ID=$(json_get '.target_project_id')
[ "$TARGET_PROJECT_ID" == "null" ] && export TARGET_PROJECT_ID=""

# Billing
export BILLING_DATASET=$(json_get '.dataset')
export BILLING_ACCOUNT_ID=$(json_get '.account_id')
export LOGS_DATASET=$(json_get '.logs_dataset')

# Vault Projects Array - Reconstruct the "['proj1','proj2']" format
VAULT_PROJECTS_LIST=($(json_get_array '.vault_projects'))
if [ ${#VAULT_PROJECTS_LIST[@]} -eq 0 ]; then
  export VAULT_PROJECTS_ARRAY="[]"
else
  printf -v VAULT_PROJECTS_STR "'%s'," "${VAULT_PROJECTS_LIST[@]}"
  export VAULT_PROJECTS_ARRAY="[${VAULT_PROJECTS_STR%,}]"
fi

# --- Dynamic Configuration ---
# Source Project: Set to the current gcloud configured project
export SOURCE_PROJECT_ID=$(gcloud config get project 2>/dev/null)
if [ -z "${SOURCE_PROJECT_ID}" ]; then
  echo "ERROR: No Google Cloud project is set. Please run 'gcloud config set project YOUR_PROJECT_ID'"
  exit 1
fi
echo "Using SOURCE_PROJECT_ID: ${SOURCE_PROJECT_ID}"

# Get the currently logged-in user email from gcloud
export USER_EMAIL=$(gcloud config get-value account 2>/dev/null)
if [ -z "${USER_EMAIL}" ]; then
  echo "ERROR: No active Google Cloud account found. Please run 'gcloud auth login'"
  exit 1
fi
echo "Using USER_EMAIL: ${USER_EMAIL} from gcloud config"

# ------------------------------------------------------------------------------
# SECTION - MAIN EXECUTION
# ------------------------------------------------------------------------------
# Mode 1: Centralized View in a Dedicated Project
# ------------------------------------------------------------------------------
# If target_project_id is provided in config.json, deploy DTS to that project.
# This single DTS instance will read logs from all projects listed in vault_projects.
# ------------------------------------------------------------------------------
if [[ -n "${TARGET_PROJECT_ID}" && "${TARGET_PROJECT_ID}" != "null" ]]; then
  echo "--- DEPLOYMENT MODE: Centralized View in a Dedicated Project ---"
  echo "Deploying to target project: ${TARGET_PROJECT_ID}"
  echo "Reading logs from projects: ${VAULT_PROJECTS_ARRAY}"
  echo ""
  echo "This script will perform the following actions:"
  echo "1. Enable Cloud Resource Manager and BigQuery Data Transfer APIs in ${TARGET_PROJECT_ID} if not already enabled."
  echo "2. Create Service Account ${SA_PREFIX}@${TARGET_PROJECT_ID}.iam.gserviceaccount.com if it does not exist."
  echo "3. Grant Service Account ${SA_PREFIX}@${TARGET_PROJECT_ID}.iam.gserviceaccount.com permissions to read billing data from ${SOURCE_PROJECT_ID} and logs from ${VAULT_PROJECTS_ARRAY}"
  echo "4. Create BigQuery Dataset ${TARGET_DATASET_ID} in ${TARGET_PROJECT_ID} (if it doesn't exist) and grant WRITER permission to Service Account ${SA_PREFIX}@${TARGET_PROJECT_ID}.iam.gserviceaccount.com and OWNER permission to project owners."
  echo "5. Configure Google-managed DTS Service Agent and assign IAM roles to run scheduled queries."
  echo "6. Create BigQuery DTS ${DTS_DISPLAY_NAME} in ${TARGET_PROJECT_ID}. If the DTS already exists, it will be deleted and recreated."
  echo "7. Trigger a backfill for the last ${BACKFILL_DAYS} days."
  echo ""
  read -p "Do you want to proceed? (y/N): " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Aborted by user."
      exit 1
  fi
  echo "Continuing..."

  deploy_billing_report "${TARGET_PROJECT_ID}" "${VAULT_PROJECTS_ARRAY}"
  if [[ $? -ne 0 ]]; then
      echo "ERROR: Deployment failed for target project ${TARGET_PROJECT_ID}."
      exit 1
  else
      echo "SUCCESS: Deployment finished for target project ${TARGET_PROJECT_ID}."
  fi
# ------------------------------------------------------------------------------
# Mode 2: Isolated Data Sets in Vault Projects
# If target_project_id is NOT provided, iterate through each project in vault_projects.
# For each project, deploy a DTS instance into that project, reading logs ONLY
# from that same project.
# ------------------------------------------------------------------------------
else
  echo "--- DEPLOYMENT MODE: Isolated Data Sets in Vault Projects ---"
  echo "target_project_id not specified in ${CONFIG_FILE}. Script will deploy to each project in 'vault_projects'."
  ALL_VAULT_PROJECTS=($(_parse_gsql_array_string "${VAULT_PROJECTS_ARRAY}"))

  if [[ ${#ALL_VAULT_PROJECTS[@]} -eq 0 ]]; then
    echo "ERROR: vault_projects is empty in $CONFIG_FILE, and no target_project_id provided."
    exit 1
  fi

  echo "The script will perform the following deployments:"
  for project in "${ALL_VAULT_PROJECTS[@]}"; do
    project=$(echo "${project}" | xargs)
    if [[ -z "${project}" ]]; then continue; fi
    echo ""
    echo "--- For project: ${project} ---"
    echo "1. Enable Cloud Resource Manager and BigQuery Data Transfer APIs in ${project} if not already enabled."
    echo "2. Create Service Account ${SA_PREFIX}@${project}.iam.gserviceaccount.com if it does not exist."
    echo "3. Grant Service Account ${SA_PREFIX}@${project}.iam.gserviceaccount.com permissions to read billing data from ${SOURCE_PROJECT_ID} and logs from ${project}"
    echo "4. Create BigQuery Dataset ${TARGET_DATASET_ID} in ${project} (if it doesn't exist) and grant WRITER permission to Service Account ${SA_PREFIX}@${project}.iam.gserviceaccount.com and OWNER permission to project owners."
    echo "5. Configure Google-managed DTS Service Agent and assign IAM roles to run scheduled queries."
    echo "6. Create BigQuery DTS ${DTS_DISPLAY_NAME} in ${project}. If the DTS already exists, it will be deleted and recreated."
    echo "7. Trigger a backfill for the last ${BACKFILL_DAYS} days."
  done
  echo ""
  read -p "Do you want to proceed with deployment to ALL projects listed above? (y/N): " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Aborted by user."
      exit 1
  fi
  echo "Continuing with deployment..."

  for project in "${ALL_VAULT_PROJECTS[@]}"; do
    project=$(echo "${project}" | xargs)
    if [[ -z "${project}" ]]; then continue; fi

    echo ""
    echo "********************************************************************************"
    echo " Processing for TARGET_PROJECT_ID: ${project} "
    echo "********************************************************************************"
    current_admin_array="['${project}']"
    deploy_billing_report "${project}" "${current_admin_array}"
    if [[ $? -ne 0 ]]; then
      echo "ERROR: Deployment failed for target project ${project}. Continuing with next project if any."
    else
      echo "SUCCESS: Deployment finished for target project ${project}."
    fi
    echo "********************************************************************************"
    echo ""
  done
fi

echo "All tasks completed."
}

# If script is run directly, execute run_main.
# If sourced, only helper functions above are defined.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_main
fi
