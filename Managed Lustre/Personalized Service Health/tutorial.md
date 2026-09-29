# Get alerted when Google Cloud incidents affect Managed Lustre

## Overview

<walkthrough-tutorial-duration duration="5"></walkthrough-tutorial-duration>

In about 5 minutes you'll set up email alerts for:

*   **Managed Lustre incidents** that Google Cloud publishes.
*   **Persistent Disk, Compute Engine, and VPC incidents** in the regions where
    you run Managed Lustre. These products power Managed Lustre, so an incident
    on them is an early warning.

Everything runs in this Cloud Shell. There's nothing to install. This panel
has all the steps, so you can close the GitHub page.

**What the setup changes.** In your project (and any client projects you
add), it:

1.  **Turns on 2 Google Cloud APIs, if they're off:**
    *   **Service Health API:** Google Cloud writes incidents that may affect
        your project to the project's Cloud Logging logs.
    *   **Cloud Monitoring API:** runs the alerts and sends the emails.
2.  **Creates an email notification channel** for the address you choose, or
    reuses one that already exists.
3.  **Creates 2 alert policies** in Cloud Monitoring, both named
    `[PSH] Managed Lustre ...`. They watch those logs and email you.

It doesn't touch your Lustre instances, VMs, networks, IAM permissions, or
billing settings. Before it changes anything, the script shows you this list
for your project and asks you to confirm. You can undo everything with one
command.

**Before you start,** have the **ID** of the project that contains your
Managed Lustre instances. You can find it in the
[project picker](https://console.cloud.google.com/projectselector2/home/dashboard)
in the **ID** column. Use the ID, not the project name.

Click **Start** to begin.

## Run the setup

Click the **Copy to Cloud Shell** button on these commands, then press
**Enter** in the terminal if they don't start on their own:

```sh
cd ~/storage-samples/Managed*Lustre/Personalized*Service*Health
./quickstart.sh
```

First it asks for your **project ID**, any **client project IDs** (projects
where your Lustre clients, like GPU VMs or GKE clusters, run; press **Enter**
to skip), and the **email address** for alerts (press **Enter** to use yours).

Then it runs 5 steps. The terminal shows each one:

1.  **Finding your Managed Lustre instances** (read-only). Their regions
    decide which Persistent Disk, Compute Engine, and VPC incidents you hear
    about. If it finds none, it tells you why (for example, a wrong project ID
    or a missing role) and asks before going on.
2.  **Checking your permissions** (read-only). If a role is missing, it stops
    and tells you which role to ask for. Nothing has changed at this point.
3.  **Review exactly what will change.** It lists each API (and whether it's
    already on), the email channel, and the 2 alert policies. Press **Enter**
    to make the changes.
4.  **Making the changes.** Each line says what was turned on, created, or
    reused.
5.  **Test alert (optional).** Press **Enter** to send one. The script pauses
    for 3 minutes first. Nothing is running in the background: new alert
    policies need a few minutes before they start watching the logs. Then it
    writes 2 fake incidents titled **TEST - NOT A REAL INCIDENT** to your
    project's logs, and each alert emails you once.

It ends with a **Checklist** and a last line that says **Setup complete** or
**NOT DONE**.

## Confirm it worked

Look at the **Checklist** the setup printed in the terminal.

*   **Setup complete**, and every line has a ✔: go to the next step.
*   **NOT DONE**, or any line has a ✘: the setup didn't finish. Fix what the
    ✘ lines say, then go back to the previous step and run the setup again.
    It's safe to re-run.

Didn't see a checklist? The setup didn't run to the end. Go back to the
previous step.

## Check your email

If you sent the test alert, you'll get two emails from
`alerting-noreply@google.com` within about 5 minutes, both marked
**TEST - NOT A REAL INCIDENT**:

*   an **Error** alert for Managed Lustre;
*   a **Warning** alert for Persistent Disk.

The **Open in Service Health dashboard** link in a test email shows
"The incident requested was not found". That's expected: the test events are
not real Service Health incidents. For a real incident, the link opens it.

No email after 10 minutes? Check your Spam folder, then the
[Alerting page](https://console.cloud.google.com/monitoring/alerting) for
open incidents. Test alerts close by themselves after 30 minutes.

## Optional: send alerts to Slack, PagerDuty, or SMS

1.  Open the [Alerting page](https://console.cloud.google.com/monitoring/alerting).
2.  Open a policy whose name starts with **[PSH] Managed Lustre** and click
    **Edit**.
3.  Under **Notifications**, add a channel.

## Finish up

<walkthrough-conclusion-trophy></walkthrough-conclusion-trophy>

If the setup said **Setup complete** and the two test emails arrived, you're
done. From now on you'll be notified when Google Cloud posts an incident that
may affect your Managed Lustre instances.

If it said **NOT DONE**, go back to **Run the setup**.

Later, from the setup folder:

*   Check that the alerts are still in place: `./quickstart.sh -c`
*   Add a project or region: `./quickstart.sh` again. It updates the existing
    alerts.
*   Send another test: `./scripts/send-test-events.sh PROJECT_ID ZONE`
*   Remove the alerts: `./scripts/remove-lustre-psh-alerts.sh -e YOUR_EMAIL PROJECT_ID`
*   See incidents on the
    [Service Health dashboard](https://console.cloud.google.com/servicehealth/incidents).
