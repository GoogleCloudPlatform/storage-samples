#!/bin/bash

# Function to call the API
call_api() {
  local project_id="$1"
  local location="$2"
  local next_page_token="$3"
  local filter="$4"

  local url="https://backupdr.googleapis.com/v1/projects/${project_id}/locations/${location}/resourceBackupConfigs"

  if [[ -n "$next_page_token" ]]; then
    url="${url}?pageToken=${next_page_token}"
  fi
  if [[ -n "$filter" ]]; then
     url="${url}?filter=${filter}"
  fi

  curl -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "Content-Type: application/json" ${url}
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

merged_data='{"resourceBackupConfigs": []}'

if [ $# -lt 4 ]; then
  echo "Please provide an output file, a resource type (projects, folders, or organizations), at least one resource ID, and one location."
  echo "Usage: $0 <output_file> <resource_type> <resource_id1> [<resource_id2> ...] locations <location1> [<location2> ...] [filter <filter_expression>]"
  exit 1
fi

output_file="$1"
resource_type="$2"
shift 2

resource_ids=()
locations=()
processing_locations=false
filter=""
filter_present=false

for arg in "$@"; do
    if [[ "$arg" == "locations" ]]; then
        processing_locations=true
        continue
    elif [[ "$arg" == "filter" ]]; then
        filter_present=true
        continue
    elif [[ "$filter_present" == true ]]; then
        filter=($arg)
    elif [[ "$processing_locations" == false && "$arg" != "locations" && "$arg" != "filter" ]]; then
        resource_ids+=("$arg")
    elif [[ "$processing_locations" == true && "$arg" != "locations" && "$arg" != "filter" ]]; then
        locations+=("$arg")
    fi
    arg_index=$((arg_index + 1))
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
        while true; do
          if [[ "$filter_present" == true ]]; then
            api_response=$(call_api "$project" "$location" "$next_page_token" "$filter")
          else
            api_response=$(call_api "$project" "$location" "$next_page_token" "")
          fi

          if [[ -n "$api_response" ]] && [[ "$api_response" != "null" ]] && [[ "$api_response" != "{}" ]]; then
            if echo "$api_response" | jq '.resourceBackupConfigs' > /dev/null 2>&1; then
              extracted_data=$(echo "$api_response" | jq '.resourceBackupConfigs')
              merged_data=$(echo "$merged_data" | jq --argjson data "$extracted_data" '.resourceBackupConfigs += $data')
            fi
            next_page_token=$(echo "$api_response" | jq -r '.nextPageToken')
            if [[ -z "$next_page_token" ]] || [[ "$next_page_token" == "null" ]]; then
              break
            fi
          else
            echo "Empty or invalid API response for project: $project, location: $location"
            break
          fi
      done
    done
  done
done

echo "$merged_data" | jq '.' > "$output_file"
echo "Output saved to: $output_file"
