# Advanced setup and reference

Most people don't need this page. The
[quick start](../README.md#quick-start-about-5-minutes) sets everything up in
about 5 minutes and checks your permissions first. Use this page if you want
to:

- set up many projects from automation or CI
  ([Option 1](#option-1-gcloud-script-non-interactive-one-or-many-projects));
- manage the alerts with [Terraform](#option-2-terraform-one-or-many-projects);
- set up by clicking in the [console](#option-3-google-cloud-console-one-project);
- change what the alerts watch ([Customize](#customize)).

## Contents

- [How Service Health decides what you see](#how-service-health-decides-what-you-see)
- [Before you begin](#before-you-begin)
- [Setup options](#setup-options)
- [Test without local tools](#test-without-local-tools)
- [Optional extras](#optional-extras)
- [Customize](#customize)
- [Repository layout](#repository-layout)
- [References](#references)

## How Service Health decides what you see

Service Health shows an incident in a project when the incident is relevant to
that project. It sets a
[relevance](https://cloud.google.com/service-health/docs/concepts) value that
can change as the incident progresses:

| Relevance | Meaning |
|---|---|
| Impacted | The incident is verified to be impacting your project. Available for some products only. |
| Related | The incident affects a product your project uses, in a location your project uses. |
| Partially related | The incident affects a product your project uses, but possibly not your project, for example in a different location. |
| Unknown | The impact on your project isn't known yet. |
| Not impacted | The incident isn't impacting your project. |

What this means for Managed Lustre:

- **Managed Lustre incidents.** When an incident lists Managed Lustre as an
  impacted product, projects that have Managed Lustre instances in an affected
  location see it as **Related**. The Managed Lustre alert catches these
  incidents.
- **Incidents on underlying products.** Managed Lustre is a managed service.
  The infrastructure that serves your instances is managed by Google and isn't
  part of your project. So an incident on Persistent Disk, Compute Engine, or
  networking isn't automatically shown in your project as a Managed Lustre
  issue.
  - Your project receives such an incident only if the project itself uses the
    product in an affected location. For example, it might have Compute Engine
    VMs or GKE nodes that run your Lustre clients.
  - The dependency alert turns these incidents into an early warning for
    Lustre. Treat it as *possible* impact on Lustre, not confirmed impact.

> [!IMPORTANT]
> Create the alerts in **every project that runs Lustre clients**, not only in
> the projects that contain your Managed Lustre instances. Projects that
> contain only Managed Lustre instances usually don't receive Persistent Disk
> or Compute Engine incidents.

## Before you begin

The quick start checks the roles below for you. With the other options,
check them yourself.

1. **Decide which projects to cover:**
   - every project that contains Managed Lustre instances;
   - every project that runs Lustre clients, such as Compute Engine VMs or GKE
     clusters that mount your file systems.
2. **List the regions where you run Managed Lustre.** Instances are zonal. This
   command prints the regions for one project:

   ```sh
   gcloud lustre instances list --location=- --project=PROJECT_ID \
       --format="value(name)" | cut -d/ -f4 | sed -E 's/-[a-z]$//' | sort -u
   ```

3. **Make sure you have these roles** in each project:

   | Role | Needed for |
   |---|---|
   | Service Usage Admin (`roles/serviceusage.serviceUsageAdmin`) | Enabling the Service Health API |
   | Personalized Service Health Viewer (`roles/servicehealth.viewer`) | Viewing Service Health events |
   | Logs Configuration Writer (`roles/logging.configWriter`) | Creating log-based alerts |
   | Monitoring AlertPolicy Editor (`roles/monitoring.alertPolicyEditor`) | Creating alert policies |
   | Monitoring NotificationChannel Editor (`roles/monitoring.notificationChannelEditor`) | Creating notification channels. Use Monitoring NotificationChannel Viewer (`roles/monitoring.notificationChannelViewer`) if you use existing channels only. |
   | Logs Writer (`roles/logging.logWriter`) | Optional: writing the test events |

4. **Install the tools** for the option you choose: the
   [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) with the
   `beta` component (`gcloud components install beta`), `python3`, and `curl`;
   or [Terraform](https://developer.hashicorp.com/terraform/install).

## Setup options

Choose one option. All options create the same two alert policies.

### Option 1: gcloud script, non-interactive (one or many projects)

```sh
git clone --depth 1 https://github.com/GoogleCloudPlatform/storage-samples.git
cd "storage-samples/Managed Lustre/Personalized Service Health/scripts"

# Preview the changes without making any.
./setup-lustre-psh-alerts.sh -n -r us-east4,asia-northeast1 \
    -e storage-oncall@example.com PROJECT_ID_1 PROJECT_ID_2

# Create the alerts.
./setup-lustre-psh-alerts.sh -r us-east4,asia-northeast1 \
    -e storage-oncall@example.com PROJECT_ID_1 PROJECT_ID_2
```

| Flag | Meaning |
|---|---|
| `-r REGIONS` | Required. Comma-separated Lustre regions. |
| `-e EMAIL` | Reuses an email notification channel for this address in each project, or creates one. |
| `-c CHANNEL` | Uses an existing notification channel (ID or full name) instead. Works with one project only, because channels belong to a project. |
| `-g` | Leaves `global` out of the dependency location filter. |
| `-u` | Updates policies that already exist: adds missing regions and the notification channel, and keeps your other edits. |
| `-n` | Dry run. |

For each project, the script enables the Service Health API, finds or creates
the notification channel, and creates the two policies. You can safely run it
again: it leaves existing policies alone and tells you if they're missing a
region or the channel (add `-u` to update them). To add
PagerDuty, Slack, or other channels afterwards, edit the policies in
**Monitoring > Alerting**.

### Option 2: Terraform (one or many projects)

The configuration needs the `hashicorp/google` provider version 5.0 or later.

```sh
cd terraform   # from the sample folder
cp terraform.tfvars.example terraform.tfvars   # then edit it
terraform init
terraform plan
terraform apply
```

For each project, the configuration enables the Service Health API
(`terraform destroy` doesn't disable it), creates an email notification
channel, and creates the two policies. Optional variables:

- `extra_notification_channels`: existing PagerDuty, Slack, Pub/Sub, or webhook
  channels per project.
- `include_global_incidents`: set to `false` to leave out `global` incidents.
- `dependency_product_ids`: add more products to watch (see
  [Customize](#customize)).

> [!NOTE]
> Cloud Monitoring variables such as `${resource.labels.event_id}` appear as
> `$${...}` in `main.tf`. This is intentional: it stops Terraform from trying
> to substitute them.

### Option 3: Google Cloud console (one project)

1. Enable the **Service Health API** for the project
   (**APIs & Services > Library**).
2. Go to **Logging > Logs Explorer**, paste the query for the policy (see
   below), and click **Run query**.
3. In the **Query results** toolbar, expand **Actions** and select **Create log
   alert**.
4. Enter the policy name from [What you get](../README.md#what-you-get) and select the
   severity. For documentation, you can paste this link to the incident:

   ```none
   [Open in Service Health dashboard](https://console.cloud.google.com/servicehealth/incidentDetails/projects%2F${resource.labels.resource_container}%2Flocations%2F${resource.labels.location}%2Fevents%2F${resource.labels.event_id}?project=${resource.labels.resource_container})
   ```

5. Click **Next** and check the query. *Optional:* add label extractors so the
   notification shows incident details, for example `title` =
   `EXTRACT(jsonPayload.title)`. The JSON files in `policies/` list all the
   extractors and a fuller documentation text that uses them.
6. Set the minimum time between notifications to **5 min** and the incident
   autoclose duration to **30 min**.
7. Select your notification channels and click **Save**.

**Query: Managed Lustre incidents**

```none
resource.type="servicehealth.googleapis.com/Event"
jsonPayload.@type="type.googleapis.com/google.cloud.servicehealth.logging.v1.EventLog"
jsonPayload.category="INCIDENT"
jsonPayload.impactedProductIds=~"6NIyMyXGmDuhgEOGEy2z"
jsonPayload.relevance!="NOT_IMPACTED"
```

**Query: dependency incidents.** Replace `us-east4|asia-northeast1` with your
Lustre regions, separated by `|`.

```none
resource.type="servicehealth.googleapis.com/Event"
jsonPayload.@type="type.googleapis.com/google.cloud.servicehealth.logging.v1.EventLog"
jsonPayload.category="INCIDENT"
jsonPayload.impactedProductIds=~"SzESm2Ux129pjDGKWD68|L3ggmi3Jy4xJmgodFA9K|BSGtCUnz6ZmyajsjgTKv"
jsonPayload.impactedLocations=~"(^|[^a-z0-9-])(us-east4|asia-northeast1|global)(-[a-z])?([^a-z0-9-]|$)"
jsonPayload.relevance!="NOT_IMPACTED"
(labels."servicehealth.googleapis.com/new_event"=true OR labels."servicehealth.googleapis.com/updated_fields"=~"'state'|'relevance'")
```

How the location expression matches:

- A region also matches its zones: `us-east4` matches `us-east4-a`.
- A region doesn't match other regions that share a prefix: `europe-west1`
  doesn't match `europe-west10`.
- To leave out incidents whose location is `global`, remove `|global`.

### Option 4: Policy JSON files with gcloud (manual)

1. In each file in `policies/`, replace `PROJECT_ID` and
   `NOTIFICATION_CHANNEL_ID`. To list your channels, run
   `gcloud beta monitoring channels list --project=PROJECT_ID`.
2. In `psh-alert-lustre-dependencies.json`, replace `REGION_REGEX` with your
   regions, for example `us-east4|asia-northeast1|global`.
3. Create the policies:

   ```sh
   gcloud services enable servicehealth.googleapis.com --project=PROJECT_ID
   gcloud monitoring policies create --project=PROJECT_ID \
       --policy-from-file=policies/psh-alert-managed-lustre.json
   gcloud monitoring policies create --project=PROJECT_ID \
       --policy-from-file=policies/psh-alert-lustre-dependencies.json
   ```

## Test without local tools

Paste the contents of
`test/test-psh-lustre-log-entry.json` into the
[`entries.write` API Explorer](https://cloud.google.com/logging/docs/reference/v2/rest/v2/entries/write)
after replacing `PROJECT_ID`, `REGION` (for example `us-east4`), and `ZONE`
(for example `us-east4-a`).

## Optional extras

### List active incidents from the API

`list-lustre-psh-events.sh` lists active incidents that involve Managed Lustre,
Persistent Disk, Compute Engine, or VPC. It needs the gcloud CLI, `curl`, and
`jq`. Use it in runbooks, dashboards, or ticket automation.

```sh
# One project. Needs roles/servicehealth.viewer on the project.
./list-lustre-psh-events.sh PROJECT_ID

# All projects in an organization that have the Service Health API enabled.
# Needs roles/servicehealth.viewer on the organization, and
# serviceusage.services.use on the quota project.
./list-lustre-psh-events.sh -o ORGANIZATION_ID QUOTA_PROJECT_ID

# Watch a different set of products.
PRODUCT_IDS="6NIyMyXGmDuhgEOGEy2z|UwaYoXQ5bHYHG6EdiPB8" ./list-lustre-psh-events.sh PROJECT_ID
```

### Send Managed Lustre maintenance events to the same channels

Managed Lustre writes scheduled, started, completed, and canceled maintenance
events to Cloud Logging (see
[View maintenance logs](https://cloud.google.com/managed-lustre/docs/maintenance#logging)).
To get them on the same channels, create a log alert (Option 3) with this
query:

```none
resource.type="lustre.googleapis.com/Instance"
logName="projects/PROJECT_ID/logs/lustre.googleapis.com%2Fmaintenance"
```

This is in addition to the maintenance email notifications, which you
configure on the console's **Communication** page.

## Customize

- **Watch more products.** Add product IDs from the table below to the
  dependency filter. In Terraform, use `dependency_product_ids`. For example:
  - Cloud Storage, if you import or export data;
  - Google Kubernetes Engine, if your clients run on GKE;
  - Cloud Key Management Service, if you use customer-managed encryption keys.
- **Alert only on confirmed incidents.** Add
  `jsonPayload.detailedCategory="CONFIRMED_INCIDENT"`. Without it, the
  dependency alert also includes *emerging* incidents, which some products
  (mainly networking) post while impact is still being assessed.
- **Alert only when your project is verified as impacted.** Replace the
  relevance condition with `jsonPayload.relevance="IMPACTED"`. This is
  available for some products only.
- **Filter on product IDs, not product names.** Product names can change;
  IDs don't.
- **Centralize alerting.** Route each project's
  `servicehealth.googleapis.com/activity` log to a central project with a
  project-level log sink, and create the policies there.

### Product IDs

| Product | Service Health product ID |
|---|---|
| Google Cloud Managed Lustre | `6NIyMyXGmDuhgEOGEy2z` |
| Persistent Disk | `SzESm2Ux129pjDGKWD68` |
| Compute Engine | `L3ggmi3Jy4xJmgodFA9K` |
| Virtual Private Cloud (VPC) | `BSGtCUnz6ZmyajsjgTKv` |
| Cloud Storage | `UwaYoXQ5bHYHG6EdiPB8` |
| Google Kubernetes Engine | `LCSbT57h59oR4W98NHuz` |
| Cloud Key Management Service | `67cSySTL7dwJZo9JWUGU` |

For the full list, see
[Supported products and locations](https://cloud.google.com/service-health/docs/supported-products-locations).

## Repository layout

| Path | Purpose |
|---|---|
| [`quickstart.sh`](../quickstart.sh) | **Start here.** One interactive command that detects your settings and sets everything up |
| [`tutorial.md`](../tutorial.md) | Guided Cloud Shell tutorial (run `teachme tutorial.md` in Cloud Shell) |
| [`policies/psh-alert-managed-lustre.json`](../policies/psh-alert-managed-lustre.json) | Alert policy for Managed Lustre incidents |
| [`policies/psh-alert-lustre-dependencies.json`](../policies/psh-alert-lustre-dependencies.json) | Alert policy for Persistent Disk, Compute Engine, and VPC incidents in your Lustre regions |
| [`scripts/setup-lustre-psh-alerts.sh`](../scripts/setup-lustre-psh-alerts.sh) | Non-interactive setup for automation and many projects |
| [`scripts/send-test-events.sh`](../scripts/send-test-events.sh) | Writes two clearly labeled test events so you can check that the alerts fire |
| [`scripts/remove-lustre-psh-alerts.sh`](../scripts/remove-lustre-psh-alerts.sh) | Deletes the policies (and optionally the email channel) |
| [`scripts/list-lustre-psh-events.sh`](../scripts/list-lustre-psh-events.sh) | Lists active Lustre-related incidents through the Service Health API |
| [`terraform/`](../terraform/) | Terraform configuration that creates both policies in one or more projects |
| [`test/test-psh-lustre-log-entry.json`](../test/test-psh-lustre-log-entry.json) | Test log entries used by `send-test-events.sh` |

## References

- [Personalized Service Health overview](https://cloud.google.com/service-health/docs/overview)
- [Concepts: event states and relevance](https://cloud.google.com/service-health/docs/concepts)
- [Configure alerts with Cloud Logging](https://cloud.google.com/service-health/docs/configure-alerts-cloud-logging)
- [Example alerting policies](https://cloud.google.com/service-health/docs/example-alerting-policies)
- [Service Health logs](https://cloud.google.com/service-health/docs/logs)
- [List events with the API](https://cloud.google.com/service-health/docs/list-events)
- [Managed Lustre maintenance](https://cloud.google.com/managed-lustre/docs/maintenance)
