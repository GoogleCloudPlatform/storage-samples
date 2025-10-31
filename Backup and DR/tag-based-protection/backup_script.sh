#!/bin/bash

# Copyright 2024 Google LLC
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

# Script to manage backup plan associations for VMs based on direct and inherited tags across multiple projects and folders.
# This script provides functionality to:
# - Associate VMs with backup plans based on direct and inherited resource tags
# - Support multiple projects and folders
# - Handle unprotection (removal) of backup associations
# - Verify project and backup plan existence
# - Process VMs in specified regions only

# Initialize script success flag
#Last Updated: 12/12/2024
SCRIPT_SUCCESS=true

echo "Starting backup plan management script..."

# Parse command-line arguments
OPTS=$(getopt \
    --options '' \
    --long backup-project-id:,location:,backup-plan:,tag-key:,tag-value:,projects:,folders:,exclude-projects:,unprotect \
    --name "$(basename "$0")" \
    -- "$@")

if [ $? != 0 ]; then
    echo "Failed to parse options" >&2
    exit 1
fi

eval set -- "$OPTS"

# Initialize variables
BACKUP_PROJECT_ID=""
LOCATION=""
BACKUP_PLAN=""
TAG_KEY=""
TAG_VALUE=""
PROJECTS=""
FOLDERS=""
EXCLUDE_PROJECTS=""
UNPROTECT=false

# Parse options
while true; do
    case "$1" in
        --backup-project-id)
            BACKUP_PROJECT_ID="$2"
            shift 2
            ;;
        --location)
            LOCATION="$2"
            shift 2
            ;;
        --backup-plan)
            BACKUP_PLAN="$2"
            shift 2
            ;;
        --tag-key)
            TAG_KEY="$2"
            shift 2
            ;;
        --tag-value)
            TAG_VALUE="$2"
            shift 2
            ;;
        --projects)
            PROJECTS="$2"
            shift 2
            ;;
        --folders)
            FOLDERS="$2"
            shift 2
            ;;
        --exclude-projects)
            EXCLUDE_PROJECTS="$2"
            shift 2
            ;;
        --unprotect)
            UNPROTECT=true
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Invalid option: $1" >&2
            exit 1
            ;;
    esac
done

# Validate required parameters
if [ "$UNPROTECT" = true ]; then
    # For unprotect, we need TAG_KEY, TAG_VALUE, and at least one project or folder
    if [ -z "$TAG_KEY" ] || [ -z "$TAG_VALUE" ]; then
        echo "ERROR: Missing required parameters for unprotection." >&2
        echo "Usage: $(basename "$0") --unprotect --tag-key TAG_KEY --tag-value TAG_VALUE [--projects PROJECTS] [--folders FOLDERS] [--exclude-projects EXCLUDE_PROJECTS]"
        exit 1
    fi
else
    # For protection, we need all parameters
    if [ -z "$BACKUP_PROJECT_ID" ] || [ -z "$LOCATION" ] || [ -z "$BACKUP_PLAN" ] || [ -z "$TAG_KEY" ] || [ -z "$TAG_VALUE" ]; then
        echo "ERROR: Missing required parameters." >&2
        echo "Usage: $(basename "$0") --backup-project-id BACKUP_PROJECT_ID --location LOCATION --backup-plan BACKUP_PLAN --tag-key TAG_KEY --tag-value TAG_VALUE [--projects PROJECTS] [--folders FOLDERS] [--exclude-projects EXCLUDE_PROJECTS]"
        exit 1
    fi
fi

# Initialize an associative array to hold the list of projects
declare -A PROJECT_ID_MAP

# Process PROJECTS
if [ -n "$PROJECTS" ]; then
    IFS=',' read -r -a PROJECTS_ARRAY <<< "$PROJECTS"
    for PROJECT_ID in "${PROJECTS_ARRAY[@]}"; do
        PROJECT_ID_MAP["$PROJECT_ID"]=1
    done
fi

# Process FOLDERS
if [ -n "$FOLDERS" ]; then
    IFS=',' read -r -a FOLDER_IDS <<< "$FOLDERS"
    for FOLDER_ID in "${FOLDER_IDS[@]}"; do
        echo "Fetching projects under folder ID: $FOLDER_ID"
        FOLDER_PROJECTS=$(gcloud projects list --filter="parent.id=${FOLDER_ID} AND parent.type=folder" --format="value(projectId)")
        for PROJECT_ID in $FOLDER_PROJECTS; do
            PROJECT_ID_MAP["$PROJECT_ID"]=1
        done
    done
fi

# Process EXCLUDE_PROJECTS
if [ -n "$EXCLUDE_PROJECTS" ]; then
    IFS=',' read -r -a EXCLUDE_PROJECTS_ARRAY <<< "$EXCLUDE_PROJECTS"
    for EXCLUDE_PROJECT_ID in "${EXCLUDE_PROJECTS_ARRAY[@]}"; do
        unset PROJECT_ID_MAP["$EXCLUDE_PROJECT_ID"]
    done
fi

if [ ${#PROJECT_ID_MAP[@]} -eq 0 ]; then
    echo "ERROR: No projects to process." >&2
    exit 1
fi

# Function to extract region from zone
get_region_from_zone() {
    local zone=$1
    echo "${zone%-*}"
}

# Function to check VM tags (updated to use resource-manager tags bindings)
check_vm_tags() {
    local PROJECT_ID="$1"
    local vm_name="$2"
    local vm_zone="$3"
    local vm_id="$4"
    
    echo "Checking tags for VM: $vm_name"
    local resource_name="//compute.googleapis.com/projects/${PROJECT_ID}/zones/${vm_zone}/instances/${vm_name}"
    
    # Get both direct and inherited tags using resource-manager
    local tag_bindings
    tag_bindings=$(gcloud resource-manager tags bindings list \
        --parent="${resource_name}" \
        --location="${vm_zone}" \
        --effective)
    
    if [[ -z "$tag_bindings" ]]; then
        echo "No tags found for VM $vm_name"
        return 1
    fi

    # Convert YAML to JSON for proper parsing
    tag_bindings_json=$(echo "$tag_bindings" | python3 -c 'import sys, yaml, json; print(json.dumps([doc for doc in yaml.safe_load_all(sys.stdin)]))')
    
    # Check for matching tag key and value
    local match
    match=$(echo "$tag_bindings_json" | jq -r --arg key "$TAG_KEY" --arg val "$TAG_VALUE" '
        .[] | 
        select(
            (.namespacedTagKey | split("/")[-1] == $key) and
            (.namespacedTagValue | split("/")[-1] == $val)
        )'
    )
    
    if [[ -n "$match" ]]; then
        # Check if tag is inherited
        local is_inherited
        is_inherited=$(echo "$match" | jq -r '.inherited // false')
        if [[ "$is_inherited" == "true" ]]; then
            echo "Found matching inherited tag ${TAG_KEY}:${TAG_VALUE} on VM $vm_name"
        else
            echo "Found matching direct tag ${TAG_KEY}:${TAG_VALUE} on VM $vm_name"
        fi
        return 0
    fi
    
    echo "No matching tag found for VM $vm_name"
    return 1
}

# Function to check if an association already exists for the VM
check_association_exists() {
    local PROJECT_ID="$1"
    local vm_name="$2"
    local vm_zone="$3"
    local vm_id="$4"

    echo "Checking backup plan associations for VM ID: $vm_id in project $PROJECT_ID..."
    local association_info
    if [ "$UNPROTECT" = true ]; then
        # Unprotect: check associations across all locations
        association_info=$(gcloud alpha backup-dr backup-plan-associations list \
            --project="${PROJECT_ID}" \
            --format="json" | \
            jq -r --arg vmid "$vm_id" '.[] | select(.resource | contains($vmid))')
    else
        # Protect: check in specific location
        association_info=$(gcloud alpha backup-dr backup-plan-associations list \
            --project="${PROJECT_ID}" \
            --location="${LOCATION}" \
            --format="json" | \
            jq -r --arg vmid "$vm_id" '.[] | select(.resource | contains($vmid))')
    fi

    if [[ -n "$association_info" ]]; then
        echo "Found association for VM ID: $vm_id"
        return 0
    else
        echo "No association found for VM ID: $vm_id"
        return 1
    fi
}

# Function to delete an existing backup plan association
delete_association() {
    local PROJECT_ID="$1"
    local association_name="$2"
    local association_location="$3"

    echo "Deleting existing backup plan association: ${association_name}..."
    if ! gcloud alpha backup-dr backup-plan-associations delete "${association_name}" \
        --project="${PROJECT_ID}" \
        --location="${association_location}" \
        --quiet; then
        echo "Failed to delete backup plan association"
        return 1
    fi

    # Wait for deletion to complete
    echo "Waiting for deletion to complete..."
    for ((i=1; i<=60; i++)); do
        if ! gcloud alpha backup-dr backup-plan-associations describe "${association_name}" \
            --project="${PROJECT_ID}" \
            --location="${association_location}" &>/dev/null; then
            echo "Association successfully deleted"
            break
        fi
        echo "Waiting... $i seconds"
        sleep 1

        if ((i == 60)); then
            echo "Timeout waiting for deletion"
            return 1
        fi
    done

    echo "Successfully deleted backup plan association"
    return 0
}

# Function to create a new backup plan association
create_association() {
    local PROJECT_ID="$1"
    local vm_name="$2"
    local vm_zone="$3"
    local vm_id="$4"

    echo "Creating new backup plan association for ${vm_name}..."
    local resource_path="projects/${PROJECT_ID}/zones/${vm_zone}/instances/${vm_id}"

    if ! gcloud alpha backup-dr backup-plan-associations create "${vm_name}-backup-association" \
        --project="${PROJECT_ID}" \
        --location="${LOCATION}" \
        --resource="${resource_path}" \
        --backup-plan="projects/${BACKUP_PROJECT_ID}/locations/${LOCATION}/backupPlans/${BACKUP_PLAN}" \
        --resource-type="compute.googleapis.com/Instance"; then
        echo "Failed to create backup plan association"
        return 1
    fi

    echo "Successfully created backup plan association"
    return 0
}

# Function to get the associated backup plan for a VM
get_associated_backup_plan() {
    local PROJECT_ID="$1"
    local vm_id="$2"
    local association_info
    association_info=$(gcloud alpha backup-dr backup-plan-associations list \
        --project="${PROJECT_ID}" \
        --location="${LOCATION}" \
        --format="json" | \
        jq -r --arg vmid "$vm_id" '.[] | select(.resource | contains($vmid))')

    if [[ -n "$association_info" ]]; then
        echo "$association_info" | jq -r '.backupPlan'
    else
        echo ""
    fi
}

# Process VM function
process_vm() {
    local PROJECT_ID="$1"
    local vm_name="$2"
    local vm_zone="$3"
    echo "Processing VM: ${vm_name} in zone ${vm_zone} of project ${PROJECT_ID}"

    # Get VM ID
    local vm_id
    vm_id=$(gcloud compute instances describe "${vm_name}" \
        --project="${PROJECT_ID}" \
        --zone="${vm_zone}" \
        --format="value(id)")

    if [[ -z "$vm_id" ]]; then
        echo "ERROR: Could not retrieve VM ID for '${vm_name}'. Please check if the VM exists."
        return 1
    fi

    echo "VM ID: $vm_id"

    # Check for direct and inherited tags
    if check_vm_tags "$PROJECT_ID" "$vm_name" "$vm_zone" "$vm_id"; then
        if check_association_exists "$PROJECT_ID" "$vm_name" "$vm_zone" "$vm_id"; then
            echo "Found existing association for VM $vm_name"

            if [ "$UNPROTECT" = true ]; then
                # Get all associations for the VM
                associations=$(gcloud alpha backup-dr backup-plan-associations list \
                    --project="${PROJECT_ID}" \
                    --format="json" | \
                    jq -c --arg vmid "$vm_id" '.[] | select(.resource | contains($vmid))')

                if [[ -z "$associations" ]]; then
                    echo "No backup plan associations found for VM $vm_name. Skipping..."
                    return 0
                fi

                # Read associations into an array
                associations_array=()
                while IFS= read -r line; do
                    associations_array+=("$line")
                done <<< "$associations"

                # Delete each association
                local success=true
                for association in "${associations_array[@]}"; do
                    association_name=$(echo "$association" | jq -r '.name')
                    association_location=$(echo "$association" | jq -r '.location')
                    echo "Deleting association $association_name in location $association_location"

                    if ! delete_association "${PROJECT_ID}" "${association_name}" "${association_location}"; then
                        echo "Failed to delete backup plan association $association_name"
                        success=false
                        continue
                    fi
                done

                if [ "$success" = false ]; then
                    return 1
                fi
                echo "Successfully deleted all backup plan associations for VM $vm_name."
                return 0
            else
                # Check if associated with correct backup plan
                local current_backup_plan
                current_backup_plan=$(get_associated_backup_plan "$PROJECT_ID" "$vm_id")
                echo "Current backup plan: $current_backup_plan"

                # Compare the current backup plan with the expected backup plan.
                local expected_backup_plan="projects/${BACKUP_PROJECT_ID}/locations/${LOCATION}/backupPlans/${BACKUP_PLAN}"
                echo "Expected backup plan: $expected_backup_plan"

                if [[ "$current_backup_plan" == "$expected_backup_plan" ]]; then
                    echo "VM $vm_name is already associated with the correct backup plan. Skipping..."
                    return 0
                else
                    echo "VM $vm_name is associated with a different backup plan. Updating..."

                    # Retrieve the numeric project number for the VM's project.
                    project_number=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")

                    # Retrieve the BPA ID for the VM resource using the numeric project number.
                    bpa_id=$(gcloud alpha backup-dr backup-plan-associations list \
                      --filter="resource=projects/${project_number}/zones/${vm_zone}/instances/${vm_id}" \
                      --format=json | jq -r '.[].name | split("/") | .[-1]')

                    if [[ -z "$bpa_id" ]]; then
                      echo "ERROR: Could not find BPA ID for VM $vm_name"
                      return 1
                    fi

                    # Build the full BPA association name.
                    association_full_name="projects/${PROJECT_ID}/locations/${LOCATION}/backupPlanAssociations/${bpa_id}"

                    echo "Deleting association with BPA ID: ${association_full_name}"
                    if ! delete_association "$PROJECT_ID" "$association_full_name" "${LOCATION}"; then
                        echo "ERROR: Failed to delete existing backup plan association for VM $vm_name."
                        return 1
                    fi

                    # Create a new association with the correct backup plan.
                    if ! create_association "$PROJECT_ID" "$vm_name" "$vm_zone" "$vm_id"; then
                        echo "ERROR: Failed to create new backup plan association for VM $vm_name."
                        return 1
                    fi
                fi
            fi
        else
            echo "No existing association found."

            if [ "$UNPROTECT" = true ]; then
                echo "Unprotect flag is set, but no association exists for VM $vm_name. Skipping..."
                return 0
            else
                echo "Creating backup plan association for VM $vm_name."
                if ! create_association "$PROJECT_ID" "$vm_name" "$vm_zone" "$vm_id"; then
                    echo "ERROR: Failed to create backup plan association for VM $vm_name."
                    return 1
                fi
            fi
        fi
    else
        echo "VM $vm_name does not have the required tag (either direct or inherited). Will not protect..."
    fi
    return 0
}

# Function to process a single project
process_project() {
    local PROJECT_ID="$1"

    echo "Processing project: $PROJECT_ID"

    # Verify Project ID
    if ! gcloud projects describe "${PROJECT_ID}" &>/dev/null; then
        echo "ERROR: Project ID '${PROJECT_ID}' not found. Please check the project ID for typos or invalid names."
        return 1
    fi

    echo "Finding VMs with tag ${TAG_KEY}:${TAG_VALUE} (including inherited tags) in project ${PROJECT_ID}..."
    matching_vms=()

    # List all VMs
    vm_list=$(gcloud compute instances list \
        --project="${PROJECT_ID}" \
        --format="csv[no-heading](name,zone)")

    while IFS=, read -r vm_name vm_zone; do
        if [[ -n "$vm_name" ]]; then
            # For protection, check region
            if [ "$UNPROTECT" != true ]; then
                # Check if VM is in the same region as the backup plan
                vm_region=$(get_region_from_zone "$vm_zone")
                if [[ "$vm_region" != "$LOCATION" ]]; then
                    echo "Skipping VM $vm_name: located in $vm_region, backup plan is in $LOCATION"
                    continue
                fi
            fi
            echo "========================================================================"

            echo "Processing VM: $vm_name"
            if process_vm "${PROJECT_ID}" "${vm_name}" "${vm_zone}"; then
                echo "✓ Successfully processed VM: ${vm_name}"
            else
                echo "✗ Failed to process VM: ${vm_name}"
                SCRIPT_SUCCESS=false
            fi
        fi
    done <<< "$vm_list"

    return 0
}

# Main function
main() {
    if [ "$UNPROTECT" != true ]; then
        # Verify Backup Project ID
        if ! gcloud projects describe "${BACKUP_PROJECT_ID}" &>/dev/null; then
            echo "ERROR: Backup Project ID '${BACKUP_PROJECT_ID}' not found. Please check the backup project ID for typos or invalid names."
            SCRIPT_SUCCESS=false
            return 1
        fi

        echo "Using Backup Project ID: ${BACKUP_PROJECT_ID}"

        # Verify backup plan exists in specified location and project
        echo "Verifying backup plan '${BACKUP_PLAN}' exists in ${LOCATION}..."

        if ! gcloud alpha backup-dr backup-plans describe "${BACKUP_PLAN}" \
            --project="${BACKUP_PROJECT_ID}" \
            --location="${LOCATION}" &>/dev/null; then
            echo "ERROR: Backup plan '${BACKUP_PLAN}' not found in project '${BACKUP_PROJECT_ID}' and location '${LOCATION}'."
            echo "Available backup plans in ${LOCATION}:"
            gcloud alpha backup-dr backup-plans list \
                --project="${BACKUP_PROJECT_ID}" \
                --location="${LOCATION}" \
                --format="table(name,state,description)"
            SCRIPT_SUCCESS=false
            return 1
        fi

        echo "Backup plan '${BACKUP_PLAN}' verified in ${LOCATION}"
    fi

    # For each project, process VMs
    for PROJECT_ID in "${!PROJECT_ID_MAP[@]}"; do
        echo "Processing Project ID: ${PROJECT_ID}"

        process_project "${PROJECT_ID}"
        if [ $? -ne 0 ]; then
            SCRIPT_SUCCESS=false
        fi
    done

    if [ "$SCRIPT_SUCCESS" = false ]; then
        echo "Script encountered errors during execution."
        return 1
    else
        echo "Script completed successfully."
        return 0
    fi
}

# Call the main function
main

echo "Script completed with status: $SCRIPT_SUCCESS"
