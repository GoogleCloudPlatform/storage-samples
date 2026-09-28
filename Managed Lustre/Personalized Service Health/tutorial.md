# Get alerted when Google Cloud incidents affect Managed Lustre

<walkthrough-tutorial-duration duration="5"></walkthrough-tutorial-duration>

In about 5 minutes you'll set up email alerts for:

*   **Managed Lustre incidents** that Google Cloud publishes.
*   **Persistent Disk, Compute Engine, and VPC incidents** in the regions where
    you run Managed Lustre. These products power Managed Lustre, so an incident
    on them is an early warning.

Everything runs in this Cloud Shell. There's nothing to install.

Click **Start** to begin.

## Pick your project

Select the project that contains your Managed Lustre instances.

<walkthrough-project-setup></walkthrough-project-setup>

Then point Cloud Shell at it:

```sh
gcloud config set project <walkthrough-project-id/>
```

## Run the quickstart

Run this one command:

```sh
./quickstart.sh
```

It will:

1.  Find your Managed Lustre instances and their regions.
2.  Use your email address for alerts. Press **Enter** to accept it, or type a
    team alias.
3.  Show you what it's going to do and ask **once** before changing anything.
4.  Create the alerts.
5.  Offer to send a test alert. Say **Y** to see it work.

**Tip:** if your Lustre clients (GPU VMs, GKE clusters) are in other projects,
add them too, for example `./quickstart.sh <walkthrough-project-id/> my-clients-project`.
Incidents on Persistent Disk and Compute Engine are only delivered to projects
that use those products.

## Check your email

If you sent the test alert, you'll get two emails from
`alerting-noreply@google.com` within about 5 minutes, both marked
**TEST - NOT A REAL INCIDENT**:

*   an **Error** alert for Managed Lustre;
*   a **Warning** alert for Persistent Disk.

You can also see them on the
[Alerting page](https://console.cloud.google.com/monitoring/alerting). Test
alerts close by themselves after 30 minutes.

## Optional: send alerts to Slack, PagerDuty, or SMS

1.  Open the [Alerting page](https://console.cloud.google.com/monitoring/alerting).
2.  Open a policy whose name starts with **[PSH] Managed Lustre** and click
    **Edit**.
3.  Under **Notifications**, add a channel.

## You're done

<walkthrough-conclusion-trophy></walkthrough-conclusion-trophy>

From now on you'll be notified when Google Cloud posts an incident that may
affect your Managed Lustre instances.

*   See current and past incidents on the
    [Service Health dashboard](https://console.cloud.google.com/servicehealth/incidents).
*   To remove the alerts later, run `./scripts/remove-lustre-psh-alerts.sh -e YOUR_EMAIL <walkthrough-project-id/>`.
