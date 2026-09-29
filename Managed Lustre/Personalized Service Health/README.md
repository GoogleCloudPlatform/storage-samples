# Service Health alerts for Google Cloud Managed Lustre

Get an email when a Google Cloud incident might affect your
[Google Cloud Managed Lustre](https://cloud.google.com/managed-lustre)
instances, including incidents on the products Managed Lustre runs on
(Persistent Disk, Compute Engine, and VPC networking).

## Quick start: about 5 minutes

This is the only thing you need to do. You'll need the **ID** of the project
that contains your Managed Lustre instances (in the
[project picker](https://console.cloud.google.com/projectselector2/home/dashboard),
**ID** column).

**1. Copy this command.** It downloads the setup files and opens a guided
tutorial next to the terminal:

```sh
git clone -q --depth 1 https://github.com/GoogleCloudPlatform/storage-samples.git ~/storage-samples 2>/dev/null || git -C ~/storage-samples pull -q --ff-only
cd ~/storage-samples/Managed*Lustre/Personalized*Service*Health && teachme tutorial.md
```

**2. Open Cloud Shell in a new tab.** Right-click the button and choose **Open
link in new tab** (or Ctrl+click, Cmd+click on a Mac), so this page stays
open. Cloud Shell is already signed in and has everything installed.

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/)

**3. Paste the command in the Cloud Shell terminal and press Enter.** The
tutorial opens in a panel on the right and walks you through the rest. From
here on, you can follow the panel instead of this page.

Prefer to stay in the terminal? Replace `teachme tutorial.md` with
`./quickstart.sh`.

The setup:

- asks for your project ID, finds your Managed Lustre instances and their
  regions, and tells you why if it can't find any;
- asks whether your Lustre clients run in other projects;
- checks your permissions before changing anything, and tells you exactly
  which role to ask for if one is missing;
- shows exactly what it will change and asks before changing anything: it
  turns on the Service Health and Cloud Monitoring APIs if they're off,
  creates or reuses an email notification channel, and creates 2 alert
  policies. It doesn't touch your Lustre instances, VMs, networks, or IAM;
- sends a test alert if you want one;
- ends with a checklist and a final line that says **Setup complete** or
  **NOT DONE**.

To confirm later that everything is in place, run `./quickstart.sh -c`. It
changes nothing and ends with **All set** only if every item passes.

You'll get two test emails from `alerting-noreply@google.com` within about 5
minutes. Check Spam if you don't see them.

The same commands work in any terminal that has the gcloud CLI installed and
signed in.

## What you get

| Alert policy | When it notifies you | Severity |
|---|---|---|
| `[PSH] Managed Lustre incidents (new + all updates)` | An incident lists Managed Lustre and is relevant to the project. Notifies when the incident is posted, on every update, and when it closes. | Error |
| `[PSH] Managed Lustre dependencies (PD / Compute Engine / VPC) in Lustre regions` | An incident on Persistent Disk, Compute Engine, or VPC lists one of your Lustre regions (or `global`). Notifies when the incident is posted and when its state or relevance changes. | Warning |

Each notification includes the incident title and latest update, its
relevance and state, the impacted products and locations, and a link to the
incident in the Service Health dashboard.

## Why add your client projects

Managed Lustre runs on infrastructure that Google manages outside your
project. So an incident on Compute Engine or Persistent Disk usually reaches
only projects that use those products, which is where your Lustre clients
(GPU VMs, GKE clusters) run. When the setup asks about client projects, list
them. Details:
[How Service Health decides what you see](docs/advanced-setup.md#how-service-health-decides-what-you-see).

## Change, test, or remove

First go to the setup folder:

```sh
cd ~/storage-samples/Managed*Lustre/Personalized*Service*Health
```

| To | Run |
|---|---|
| Check that the alerts are in place | `./quickstart.sh -c PROJECT_ID...`. Changes nothing. Ends with **All set** only if every item passes. |
| Add a project or region, or change the email | `./quickstart.sh` again. It updates the existing alerts instead of creating duplicates. |
| Send another test alert | `./scripts/send-test-events.sh PROJECT_ID ZONE`, for example `us-east4-a`. Wait at least 5 minutes between tests. |
| Remove the alerts | `./scripts/remove-lustre-psh-alerts.sh -e EMAIL PROJECT_ID` (add `-n` to preview) |
| Add Slack, PagerDuty, or SMS | Open a `[PSH] Managed Lustre` policy in **Monitoring > Alerting** and add a notification channel. |

Removing the alerts doesn't turn off the Service Health API.

## What these alerts don't cover

- **Dependency alerts are an early warning, not confirmation.** An incident on
  Persistent Disk, Compute Engine, or VPC in your region may not affect your
  Lustre instances. Check your Lustre client metrics and the incident details.
- **Service Health covers incidents that Google Cloud publishes.** Some issues
  affect only a small number of resources and might not appear in Service
  Health. If you see impact without a matching incident, open a support case.
- **New projects:** Service Health can take up to 24 hours to start processing
  events after the API is turned on.

To catch symptoms directly, pair these alerts with metric-based alerts on
Managed Lustre metrics. See
[Monitor instances and operations](https://cloud.google.com/managed-lustre/docs/monitoring).

## Advanced setup

Most people can skip this. See
[docs/advanced-setup.md](docs/advanced-setup.md) to:

- set up many projects from automation or CI;
- use Terraform or the Google Cloud console instead;
- watch more products or change the alert filters;
- list incidents from the API, or send Lustre maintenance events to the same
  channels.

## Contributing and support

See [CONTRIBUTING.md](CONTRIBUTING.md). This is sample code provided under the
[Apache 2.0 license](LICENSE). For help with Managed Lustre or Service Health,
contact [Google Cloud Support](https://cloud.google.com/support).
