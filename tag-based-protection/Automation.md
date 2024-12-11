# Automated GCP VM Backup Management

Ashika Ganesh| Last Updated: Dec 11, 2024

## Table of Contents
- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Detailed Implementation Steps](#detailed-implementation-steps)
  - [1. Initial Setup in Cloud Shell](#1-initial-setup-in-cloud-shell)
  - [2. Create Working Directory and Files](#2-create-working-directory-and-files)
  - [3. Set Up Container Registry](#3-set-up-container-registry)
  - [4. Create and Configure Service Account](#4-create-and-configure-service-account)
  - [5. Verify Backup Plan](#5-verify-backup-plan)
  - [6. Create Cloud Run Job](#6-create-cloud-run-job)
  - [7. Set Up Cloud Scheduler](#7-set-up-cloud-scheduler)
  - [8. Testing](#8-testing)
  - [9. Monitoring and Troubleshooting](#9-monitoring-and-troubleshooting)
    - [View Job History](#view-job-history)
    - [Check Scheduler Job Status](#check-scheduler-job-status)
    - [Common Issues and Solutions](#common-issues-and-solutions)
  - [10. Maintenance Tasks](#10-maintenance-tasks)
    - [Update Job Configuration](#update-job-configuration)
    - [Update Schedule](#update-schedule)
- [Important Notes](#important-notes)
- [Best Practices](#best-practices)

## Overview

This guide provides detailed, step-by-step instructions for implementing an automated backup management system in Google Cloud Platform (GCP). This solution automates VM backup management using Cloud Run Jobs, Cloud Scheduler, and custom scripts.


## Prerequisites

1. Access to Google Cloud Console  
2. Required GCP Projects:  
   - Backup project (where backups will be stored)  
   - Target project (where VMs are located)  
3. Enable required APIs in both projects:

```
# Run these commands in both projects
gcloud services enable \
    cloudscheduler.googleapis.com \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    backupdr.googleapis.com
```

## Detailed Implementation Steps

### 1\. Initial Setup in Cloud Shell

1. Open Google Cloud Console ([https://console.cloud.google.com](https://console.cloud.google.com))  
2. Click the "Activate Cloud Shell" button (\>\_ icon) at the top right  
3. Wait for Cloud Shell to initialize  
4. Verify you're in the correct project:

```
# Check current project
gcloud config get-value project

# If needed, set the correct project
gcloud config set project YOUR-PROJECT-NAME
```

### 2\. Create Working Directory and Files

1. Create and navigate to working directory:

```
mkdir test-docker
cd test-docker
```

2. Create Dockerfile:

```
# Create new file
nano Dockerfile
```

3. Copy and paste this content into the Dockerfile (use Ctrl+V or right-click paste):

```
# Use official Google Cloud SDK image from Docker Hub
FROM google/cloud-sdk:slim

# Install required packages
RUN apt-get update && apt-get install -y jq gettext

# Copy the script into the container
COPY backup_script.sh /app/
WORKDIR /app

# Make the script executable
RUN chmod +x /app/backup_script.sh

# Add authentication wrapper script
RUN echo '#!/bin/bash\n\
# Activate service account\n\
gcloud auth list\n\
echo "Current project: $(gcloud config get-value project)"\n\
\n\
# Run the backup script with provided arguments\n\
exec /app/backup_script.sh "$@"' > /app/entrypoint.sh && \
   chmod +x /app/entrypoint.sh

# Set the entrypoint
ENTRYPOINT ["/app/entrypoint.sh"]

```

4. Save the Dockerfile:  
     
   - Press Ctrl+X  
   - Press Y to confirm saving  
   - Press Enter to keep the filename

   

5. Create cloudbuild.yaml:

```
# Create new file
nano cloudbuild.yaml
```

6. Copy and paste this content into cloudbuild.yaml: Make sure your [XXX-compute@developer.gserviceaccount.com](mailto:XXX-compute@developer.gserviceaccount.com) has Roles: GCS Object Lister, Logs Writer, and Storage Object User.

```
steps:
 # Print the working directory contents for debugging
 - name: 'ubuntu'
   args: ['ls', '-la']
  
 # Build the container
 - name: 'gcr.io/cloud-builders/docker'
   args:
     - 'build'
     - '-t'
     - 'us-central1-docker.pkg.dev/$PROJECT_ID/backup-scripts/backup-script:latest'
     - '.'
  # Push to Artifact Registry
 - name: 'gcr.io/cloud-builders/docker'
   args:
     - 'push'
     - 'us-central1-docker.pkg.dev/$PROJECT_ID/backup-scripts/backup-script:latest'

images:
 - 'us-central1-docker.pkg.dev/$PROJECT_ID/backup-scripts/backup-script:latest'

```

7. Save cloudbuild.yaml:  
     
   - Press Ctrl+X  
   - Press Y to confirm saving  
   - Press Enter to keep the filename

   

8. Copy your backup\_script.sh to Cloud Shell:  
     
   - Click the three-dot menu in Cloud Shell  
   - Select "Upload file"  
   - Choose your backup\_script.sh file  
   - Wait for upload to complete

   

9. Make the backup script executable:

```
chmod +x backup_script.sh
```

### 3\. Set Up Container Registry

1. Create Artifact Registry repository.   
   - Make sure you update the location to be the location of your Backup Plan you intend to use. 

```
gcloud artifacts repositories create backup-scripts \
    --repository-format=docker \
    --location=us-central1 \
    --description="Repository for backup scripts"
```

2. Build locally

```
# Build locally 
docker build -t backup-script:latest .
```

3. Tag for Artifact Registry. Update the project name to be your current project where backups reside.   
   - Update the *us-central1* to be the same as your desired region   
   - Update YOUR-PROJECT-NAME to be your project where VMs exist.

```
# Tag for Artifact Registry 
docker tag backup-script:latest us-central1-docker.pkg.dev/YOUR-PROJECT-NAME/backup-scripts/backup-script:latest 
```

4. Push to Artifact Registry.  Update the project name to be your current project where backups reside.   
   - Update *us-central1* to be the same as your desired region  
   - Update YOUR-PROJECT-NAME to be your project where VMs exist.

```
# Push to Artifact Registry 
docker push us-central1-docker.pkg.dev/YOUR-PROJECT-NAME/backup-scripts/backup-script:latest
```

### 4\. Create and Configure Service Account

1. Create the service account:

```
# Create service account
gcloud iam service-accounts create backup-script-sa \
    --display-name="Backup Script Service Account"
```

2. Grant permissions on the backup project where your backup plan and backup vaults reside (YOUR-PROJECT-NAME):  
   - Update the below to use your project name where your backup plan resides.

```
# Base permissions
gcloud projects add-iam-policy-binding YOUR-PROJECT-NAME \
    --member="serviceAccount:backup-script-sa@YOUR-PROJECT-NAME.iam.gserviceaccount.com" \
    --role="roles/viewer" \
    --condition=None

gcloud projects add-iam-policy-binding YOUR-PROJECT-NAME \
    --member="serviceAccount:backup-script-sa@YOUR-PROJECT-NAME.iam.gserviceaccount.com" \
    --role="roles/backupdr.admin" \
    --condition=None

gcloud projects add-iam-policy-binding YOUR-PROJECT-NAME \
    --member="serviceAccount:backup-script-sa@YOUR-PROJECT-NAME.iam.gserviceaccount.com" \
    --role="roles/iam.serviceAccountUser" \
    --condition=None

# Additional required permissions (added based on troubleshooting)
gcloud projects add-iam-policy-binding YOUR-PROJECT-NAME \
    --member="serviceAccount:backup-script-sa@YOUR-PROJECT-NAME.iam.gserviceaccount.com" \
    --role="roles/backupdr.computeEngineBackupAdmin" \
    --condition=None

gcloud projects add-iam-policy-binding YOUR-PROJECT-NAME \
    --member="serviceAccount:backup-script-sa@YOUR-PROJECT-NAME.iam.gserviceaccount.com" \
    --role="roles/compute.instanceAdmin.v1" \
    --condition=None
```

3. Grant permissions on target project (TARGET-PROJECT-NAME):

```
# Base permissions
gcloud projects add-iam-policy-binding TARGET-PROJECT-NAME \
    --member="serviceAccount:backup-script-sa@TARGET-PROJECT-NAME.iam.gserviceaccount.com" \
    --role="roles/viewer" \
    --condition=None

gcloud projects add-iam-policy-binding TARGET-PROJECT-NAME \
    --member="serviceAccount:backup-script-sa@TARGET-PROJECT-NAME.iam.gserviceaccount.com" \
    --role="roles/resourcemanager.tagViewer" \
    --condition=None

gcloud projects add-iam-policy-binding TARGET-PROJECT-NAME \
    --member="serviceAccount:backup-script-sa@TARGET-PROJECT-NAME.iam.gserviceaccount.com" \
    --role="roles/compute.viewer" \
    --condition=None

# Additional required permissions (added based on troubleshooting)
gcloud projects add-iam-policy-binding TARGET-PROJECT-NAME \
    --member="serviceAccount:backup-script-sa@TARGET-PROJECT-NAME.iam.gserviceaccount.com" \
    --role="roles/backupdr.computeEngineBackupAdmin" \
    --condition=None

gcloud projects add-iam-policy-binding TARGET-PROJECT-NAME \
    --member="serviceAccount:backup-script-sa@TARGET-PROJECT-NAME.iam.gserviceaccount.com" \
    --role="roles/compute.instanceAdmin.v1" \
    --condition=None
```

### 5\. Verify Backup Plan

1. List existing backup plans to get the exact name:

```
gcloud alpha backup-dr backup-plans list \
    --project=YOUR-PROJECT-NAME \
    --location=us-central1 \
    --format="table(name,state,description)"
```

2. Note the full backup plan name from the output.  
   - it should look like: "projects/prod-demo-vault/locations/us-central1/backupPlans/bp-bronze"

### 6\. Create Cloud Run Job

1. Create the Cloud Run job.   
   - Be sure to update YOUR-PROJECT-NAME with your project.  
   - Be sure to also update the values of the location, backup plan name, tag key, tag value, and target project where your VMs reside.   
   - If you want to make changes after creation, you can modify through editing the YAML in the Cloud run Jobs YAML tab. 

```
gcloud run jobs create backup-script-job \
    --image=us-central1-docker.pkg.dev/YOUR-PROJECT-NAME/backup-scripts/backup-script:latest \
    --service-account=backup-script-sa@YOUR-PROJECT-NAME.iam.gserviceaccount.com \
    --region=us-central1 \
    --args="--backup-project-id=YOUR-PROJECT-NAME" \
    --args="--location=us-central1" \
    --args="--backup-plan=bp-automation" \
    --args="--tag-key=environment" \
    --args="--tag-value=production" \
    --args="--projects=TARGET-PROJECT-NAME" \
    --max-retries=3 \
    --task-timeout=3600s

```

### 7\. Set Up Cloud Scheduler

1. Grant additional permissions for scheduler:

```
gcloud projects add-iam-policy-binding YOUR-PROJECT-NAME \
    --member="serviceAccount:backup-script-sa@YOUR-PROJECT-NAME.iam.gserviceaccount.com" \
    --role="roles/run.invoker" \
    --condition=None
```

2. Create scheduler job:  
   The schedule `0 */3 * * *` runs the job in UTC every 3 hours. You can modify this using [standard cron syntax](https://cloud.google.com/scheduler/docs/configuring/cron-job-schedules). Alternatively,  `0 0 * * *` runs the job in UTC at midnight. 

```
gcloud scheduler jobs create http backup-script-scheduler \
    --schedule="0 */3 * * *" \
    --location=us-central1 \
    --uri="https://us-central1-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/YOUR-PROJECT-NAME/jobs/backup-script-job:run" \
    --http-method=POST \
    --oauth-service-account-email=backup-script-sa@YOUR-PROJECT-NAME.iam.gserviceaccount.com
```

### 8\. Testing

1. Execute the job manually:  
   \- You may be asked to pick a region. This must be the same region as your backup plan.

```
gcloud run jobs execute backup-script-job
```

2. Check execution status with  
   Option 1 \- with Cloud Console:  
     
   1. Navigate to [Cloud Run \- 'Jobs' tab](https://console.cloud.google.com/run).  
   2. Here you will find your “backup-script-job”. Click into the details.  
   3. View a history of all passed runs that have been executed and their status.  
      1. View logs on every run to see if the script executed with a success status.

   

   Option 2 \- with CLI:

````
```
# Get the latest execution ID
LATEST_EXECUTION=$(gcloud run jobs executions list --job backup-script-job --limit=1 --format="value(name)")

# View logs
gcloud logging read "resource.type=cloud_run_job AND resource.labels.job_name=backup-script-job AND resource.labels.execution_name=${LATEST_EXECUTION}" --limit=100 --format="table(textPayload)"
```
````

### 9\. Monitoring and Troubleshooting

#### View Job History

```
gcloud run jobs executions list --job backup-script-job
```

#### Check Scheduler Job Status

```
gcloud scheduler jobs list
```

#### Common Issues and Solutions

1. **Permission Denied Errors**  
     
   - Verify all IAM roles are correctly assigned  
   - Check both projects have the necessary permissions  
   - Ensure service account exists and is properly configured with the required Roles

   

2. **Backup Plan Not Found**  
     
   - Verify the backup plan exists using the list command  
   - Check the full backup plan name format  
   - Ensure you are using the correct location of the backup plan  
   - Ensure you're in the correct project

   

3. **Project Access Issues**  
     
   - Verify project IDs are correct  
   - Check if all required APIs are enabled  
   - Ensure service account has proper project access

### 10\. Maintenance Tasks

#### Update Job Configuration

```
gcloud run jobs update backup-script-job \
    [include any parameters you want to change]
```

#### Update Schedule

```
gcloud scheduler jobs update http backup-script-scheduler \
    --schedule="NEW_SCHEDULE"
```

## Important Notes

- Replace project IDs if different from examples  
- The scheduler uses UTC timezone  
- Job timeout is set to 1 hour (3600s)  
- Job will retry up to 3 times on failure  
- All permissions are set without conditions for simplicity

## Best Practices

1. Regularly monitor job execution logs  
2. Keep track of successful/failed backups  
3. Maintain documentation of any custom modifications  
4. Regularly review and update permissions as needed

