#!/bin/bash
#sh analyze_dup_backup_configs.sh double_configs.json projects demo-project locations us-central1

# Function to call the API
call_api() {
  local project_id="$1"
  local location="$2"
  local next_page_token="$3"

  local url="https://backupdr.googleapis.com/v1/projects/${project_id}/locations/${location}/resourceBackupConfigs?filter=backup_configured=true%20AND%20target_resource_type=%22COMPUTE_ENGINE_VM%22"

  if [[ -n "$next_page_token" ]]; then
    url="${url}&pageToken=${next_page_token}"
  fi

  curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "Content-Type: application/json" "${url}"
}

# Function to get projects from folder or organization
get_projects() {
  local resource_type="$1"
  local resource_id="$2"

  if [[ "$resource_type" == "folders" ]]; then
    gcloud projects list --filter="parent.id:$resource_id AND parent.type:folder" --format="value(projectId)"
  elif [[ "$resource_type" == "organizations" ]]; then
    gcloud projects list --filter="parent.id:$resource_id AND parent.type:organization" --format="value(projectId)"
  else
    echo "Invalid resource type. Please use 'folders' or 'organizations'."
    exit 1
  fi
}

# Function to create the custom JSON output
create_custom_json() {
  local vm="$1"
  local project="$2"
  local template_name="$3"
  local backup_plan_name="$4"

  if [[ -z "$vm" || -z "$project" || -z "$template_name" || -z "$backup_plan_name" ]]; then
    echo "Error: Missing values to create JSON."
    return 1
  fi

  echo '{'
  echo "  \"vm\": \"${vm}\","
  echo "  \"project\": \"${project}\","
  echo '  "backupConfigsDetails": ['
  echo '    {'
  echo "      \"templateName\": \"${template_name}\","
  echo "      \"backupPlanName\": \"${backup_plan_name}\""
  echo '    }'
  echo '  ]'
  echo '}'
}

if [[ $# -lt 5 ]]; then
  echo "Please provide an output file, a resource type (folders, organizations, or projects), at least one resource ID, and one location."
  echo "Usage: $0 <output_file> <resource_type> <resource_id1> [<resource_id2> ...] locations <location1> [<location2> ...]"
  exit 1
fi

count=0
output_file="$1"
resource_type="$2"
shift 2

resource_ids=()
locations=()
processing_locations=false
found_repeated_resources=false

# Clear the output file
> "$output_file"

for arg in "$@"; do
    if [[ "$arg" == "locations" ]]; then
        processing_locations=true
        continue
    elif [[ "$processing_locations" == false && "$arg" != "locations" ]]; then
        resource_ids+=("$arg")
    elif [[ "$processing_locations" == true && "$arg" != "locations" ]]; then
        locations+=("$arg")
    fi
done

for resource_id in "${resource_ids[@]}"; do
    if [[ "$resource_type" == "projects" ]]; then
        projects="$resource_id"
    else
        projects=$(get_projects "$resource_type" "$resource_id")
    fi
	
    for project in $projects; do
      for location in "${locations[@]}"; do
        next_page_token=""
        echo "Processing project: $project, location: $location"
        while true; do
            api_response=$(call_api "$project" "$location" "$next_page_token")

          if [[ -z "$api_response" ]] || [[ "$api_response" == "null" ]]; then
            echo "Empty or invalid API response for project: $project, location: $location"
            break
          fi
          
          # Check for the specific error response and stop processing if there is an error
          error_message=$(echo "$api_response" | jq -r '.error?.message // empty')
          if [[ -n "$error_message" ]]; then
            echo "API Error for project: $project, location: $location: $error_message"
            break
          fi

          # Proceed with processing only if there is no error and the response is valid json
          JQ_RESULTS=$(echo "$api_response" | jq -c '
            .resourceBackupConfigs[] | select( . != null) |
            select(.backupConfigsDetails | type == "array") |
            {
              vm: .targetResourceDisplayName,
              backupConfigsDetails: .backupConfigsDetails |
              (
                [
                  (.[ ] | select(.type == "BACKUPDR_TEMPLATE") | .),
                  (.[ ] | select(.type == "BACKUPDR_BACKUP_PLAN") | .)
                ]
              )
            } | select( .backupConfigsDetails | length > 1)
          ')

	        if [[ -n "$JQ_RESULTS" ]] && [[ "$JQ_RESULTS" != "[]" ]]; then
	              found_repeated_resources=true
	              echo "Found resourceBackupConfigs with at least one BACKUPDR_TEMPLATE and one BACKUPDR_BACKUP_PLAN for project: $project, location: $location:"
              
	              while IFS= read -r jq_result; do
	                vm=$(echo "$jq_result" | jq -r '.vm')
	                template_name=$(echo "$jq_result" | jq -r '.backupConfigsDetails | map(select(.type == "BACKUPDR_TEMPLATE"))[0].backupConfigSource')
	                backup_plan_name=$(echo "$jq_result" | jq -r '.backupConfigsDetails | map(select(.type == "BACKUPDR_BACKUP_PLAN"))[0].backupConfigSource')
                
	                custom_json=$(create_custom_json "$vm" "$project" "$template_name" "$backup_plan_name")
	                echo "$custom_json" >> "$output_file"
			count=$((count+1))
	              done <<< "$JQ_RESULTS"
	          fi


          next_page_token=$(echo "$api_response" | jq -r '.nextPageToken')
          if [[ -z "$next_page_token" ]] || [[ "$next_page_token" == "null" ]]; then
            break
          fi

      done
    done
  done
done


if [[ "$found_repeated_resources" == true ]]; then
    echo "Analysis Complete: Found ${count} VMs with at least one BACKUPDR_TEMPLATE and one BACKUPDR_BACKUP_PLAN in at least one of the responses."
else
    echo "Analysis Complete: No resourceBackupConfigs were found with at least one BACKUPDR_TEMPLATE and one BACKUPDR_BACKUP_PLAN."
fi

echo "Output saved to: $output_file"

