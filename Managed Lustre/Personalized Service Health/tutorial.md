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

## Run the setup

Run this one command:

```sh
cd ~/storage-samples/"Managed Lustre/Personalized Service Health" && ./quickstart.sh
```

Answer a few questions. Pressing **Enter** accepts the suggested answer.

1.  **Project:** press **Enter** to use the one you picked.
2.  **Client projects:** if your Lustre clients (GPU VMs, GKE clusters) run in
    other projects, type their IDs. This matters: incidents on Compute Engine
    and Persistent Disk only reach projects that use those products.
3.  **Email:** press **Enter** to use yours, or type a team alias.
4.  **Go ahead?** press **Enter**.
5.  **Send a test alert?** press **Enter**. The script waits 3 minutes for the
    new alerts to become active, then sends it.

Before it changes anything, the script checks your permissions. If a role is
missing, it stops and tells you which role you need, with a command you can
send to a project owner. Run it again after you get the role.

## Check your email

At the end, the script prints a checklist. Every line should have a ✔.

If you sent the test alert, you'll get two emails from
`alerting-noreply@google.com` within about 5 minutes, both marked
**TEST - NOT A REAL INCIDENT**:

*   an **Error** alert for Managed Lustre;
*   a **Warning** alert for Persistent Disk.

No email? Check your Spam folder, then the
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
*   To add a project or region later, run `./quickstart.sh` again. It updates
    the existing alerts.
*   To remove the alerts, run `./scripts/remove-lustre-psh-alerts.sh -e YOUR_EMAIL <walkthrough-project-id/>`.
