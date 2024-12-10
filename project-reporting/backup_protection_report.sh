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

# Script to generate a report of VMs and their backup protection status
# across multiple projects and folders

# Initialize script success flag
SCRIPT_SUCCESS=true

# Parse command-line arguments
OPTS=$(getopt \
    --options '' \
    --long projects:,folders:,exclude-projects:,output-file: \
    --name "$(basename "$0")" \
    -- "$@")

if [ $? != 0 ]; then
    echo "Failed to parse options" >&2
    exit 1
fi

eval set -- "$OPTS"

# Initialize variables
PROJECTS=""
FOLDERS=""
EXCLUDE_PROJECTS=""
OUTPUT_FILE="backup_protection_report.txt"

# Parse options
while true; do
    case "$1" in
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
        --output-file)
            OUTPUT_FILE="$2"
            shift 2
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

# Validate parameters
if [ -z "$PROJECTS" ] && [ -z "$FOLDERS" ]; then
    echo "ERROR: Either --projects or --folders must be specified." >&2
    echo "Usage: $(basename "$0") [--projects PROJECTS] [--folders FOLDERS] [--exclude-projects EXCLUDE_PROJECTS] [--output-file OUTPUT_FILE]"
    exit 1
fi

echo "🔍 Initializing backup protection status report..."

# Initialize an associative array to hold the list of projects
declare -A PROJECT_ID_MAP

# Process PROJECTS
if [ -n "$PROJECTS" ]; then
    echo "📋 Processing specified projects..."
    IFS=',' read -r -a PROJECTS_ARRAY <<< "$PROJECTS"
    for PROJECT_ID in "${PROJECTS_ARRAY[@]}"; do
        echo "  → Adding project: $PROJECT_ID"
        PROJECT_ID_MAP["$PROJECT_ID"]=1
    done
fi

# Process FOLDERS
if [ -n "$FOLDERS" ]; then
    echo "📁 Processing specified folders..."
    IFS=',' read -r -a FOLDER_IDS <<< "$FOLDERS"
    for FOLDER_ID in "${FOLDER_IDS[@]}"; do
        echo "  → Fetching projects under folder ID: $FOLDER_ID"
        FOLDER_PROJECTS=$(gcloud projects list --filter="parent.id=${FOLDER_ID} AND parent.type=folder" --format="value(projectId)")
        for PROJECT_ID in $FOLDER_PROJECTS; do
            echo "    → Found project: $PROJECT_ID"
            PROJECT_ID_MAP["$PROJECT_ID"]=1
        done
    done
fi

# Process EXCLUDE_PROJECTS
if [ -n "$EXCLUDE_PROJECTS" ]; then
    echo "🚫 Processing exclusion list..."
    IFS=',' read -r -a EXCLUDE_PROJECTS_ARRAY <<< "$EXCLUDE_PROJECTS"
    for EXCLUDE_PROJECT_ID in "${EXCLUDE_PROJECTS_ARRAY[@]}"; do
        echo "  → Excluding project: $EXCLUDE_PROJECT_ID"
        unset PROJECT_ID_MAP["$EXCLUDE_PROJECT_ID"]
    done
fi

# Initialize counters for summary
total_vms=0
protected_vms=0
unprotected_vms=0

# Create or clear the output file
> "$OUTPUT_FILE"

# Function to show spinner while waiting
show_spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Function to check if a VM has backup protection
check_vm_protection() {
    local PROJECT_ID="$1"
    local vm_name="$2"
    local vm_zone="$3"
    
    # Get VM ID
    local vm_id
    vm_id=$(gcloud compute instances describe "${vm_name}" \
        --project="${PROJECT_ID}" \
        --zone="${vm_zone}" \
        --format="value(id)" 2>/dev/null)

    if [[ -z "$vm_id" ]]; then
        return 1
    fi

    # Check for backup plan associations
    local association_info
    association_info=$(gcloud alpha backup-dr backup-plan-associations list \
        --project="${PROJECT_ID}" \
        --format="json" | \
        jq -r --arg vmid "$vm_id" '.[] | select(.resource | contains($vmid))')

    if [[ -n "$association_info" ]]; then
        # Get backup plan details
        local backup_plan
        backup_plan=$(echo "$association_info" | jq -r '.backupPlan')
        echo "$backup_plan"
        return 0
    else
        return 1
    fi
}

# Process each project
project_count=0
total_projects=${#PROJECT_ID_MAP[@]}

for PROJECT_ID in "${!PROJECT_ID_MAP[@]}"; do
    ((project_count++))
    echo -e "\n🔄 Processing project ($project_count/$total_projects): $PROJECT_ID"
    
    # Verify Project ID exists
    if ! gcloud projects describe "${PROJECT_ID}" &>/dev/null; then
        echo "❌ ERROR: Project ID '${PROJECT_ID}' not found. Skipping..." >&2
        continue
    fi

    # Create project section in report
    echo -e "\n=== Project: ${PROJECT_ID} ===" >> "$OUTPUT_FILE"
    
    # Initialize project-level counters
    project_total=0
    project_protected=0
    project_unprotected=0

    # Get list of all VMs in project
    echo "📝 Fetching VM list..."
    vm_list=$(gcloud compute instances list \
        --project="${PROJECT_ID}" \
        --format="csv[no-heading](name,zone)" 2>/dev/null)
    
    # Count total VMs for progress
    vm_count=0
    total_project_vms=$(echo "$vm_list" | grep -c "^")
    
    while IFS=, read -r vm_name vm_zone; do
        if [[ -n "$vm_name" ]]; then
            ((vm_count++))
            ((project_total++))
            ((total_vms++))
            
            # Show progress
            echo -ne "\r💻 Processing VM ($vm_count/$total_project_vms): $vm_name in $vm_zone"
            
            # Check VM protection status
            backup_plan=$(check_vm_protection "$PROJECT_ID" "$vm_name" "$vm_zone")
            if [[ $? -eq 0 ]]; then
                ((project_protected++))
                ((protected_vms++))
                echo "✓ Protected: $vm_name (Zone: $vm_zone)" >> "$OUTPUT_FILE"
                echo "  Backup Plan: $backup_plan" >> "$OUTPUT_FILE"
            else
                ((project_unprotected++))
                ((unprotected_vms++))
                echo "✗ Unprotected: $vm_name (Zone: $vm_zone)" >> "$OUTPUT_FILE"
            fi
        fi
    done <<< "$vm_list"
    
    echo -e "\n✅ Completed processing $total_project_vms VMs in project $PROJECT_ID"

    # Add project summary
    echo -e "\nProject Summary:" >> "$OUTPUT_FILE"
    echo "Total VMs: $project_total" >> "$OUTPUT_FILE"
    echo "Protected VMs: $project_protected" >> "$OUTPUT_FILE"
    echo "Unprotected VMs: $project_unprotected" >> "$OUTPUT_FILE"
    echo "Protection Rate: $(( (project_protected * 100) / project_total ))%" >> "$OUTPUT_FILE"
done

echo -e "\n📊 Generating final report..."

# Create overall summary at the top of the file
{
    echo "=== Backup Protection Status Report ==="
    echo "Generated on: $(date)"
    echo -e "\nOverall Summary:"
    echo "Total VMs: $total_vms"
    echo "Protected VMs: $protected_vms"
    echo "Unprotected VMs: $unprotected_vms"
    echo "Overall Protection Rate: $(( (protected_vms * 100) / total_vms ))%"
    echo -e "\n=== Detailed Report ===\n"
    cat "$OUTPUT_FILE"
} > "$OUTPUT_FILE.tmp" && mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE"

echo "✨ Report generated successfully: $OUTPUT_FILE"