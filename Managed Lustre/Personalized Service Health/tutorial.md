# Get alerted when Google Cloud incidents affect Managed Lustre

<walkthrough-tutorial-duration duration="5"></walkthrough-tutorial-duration>

In about 5 minutes you'll set up email alerts for:

*   **Managed Lustre incidents** that Google Cloud publishes.
*   **Persistent Disk, Compute Engine, and VPC incidents** in the regions where
    you run Managed Lustre. These products power Managed Lustre, so an incident
    on them is an early warning.

Everything runs in this Cloud Shell. There's nothing to install. This panel
has all the steps, so you can close the GitHub page.

Before you start, have the **ID** of the project that contains your Managed
Lustre instances. You can find it in the
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

The script asks these questions, in this order. Pressing **Enter** accepts the
suggestion in `[brackets]`.

*   **Project ID:** the ID of the project that contains your Lustre instances.
*   **Client project IDs:** if your Lustre clients (GPU VMs, GKE clusters) run
    in other projects, their IDs. Otherwise press **Enter**.
*   **Email address for alerts:** press **Enter** to use yours, or type a team
    alias.
*   **Go ahead?** press **Enter**.
*   **Send a test alert?** press **Enter**. The script waits 3 minutes for the
    new alerts to become active, then sends it.

The script first lists your Managed Lustre instances. If it can't find any, it
tells you why (for example, a wrong project ID or a missing role) and asks
before going on. Run it again with the right project ID.

It also checks your permissions before it changes anything. If a role is
missing, it stops and tells you which role to ask for.

When it finishes, the last line says **Setup complete** or **NOT DONE**. If
it says NOT DONE, fix the items marked ✘ and run the command again.

## Confirm it worked

Run this check. It changes nothing:

```sh
cd ~/storage-samples/Managed*Lustre/Personalized*Service*Health
./quickstart.sh -c
```

Enter the same project ID. To check your client projects too, list all the
IDs after `-c`, separated by spaces.

*   **All set: the alerts are in place.** Go to the next step.
*   **NOT DONE** or any ✘: the setup didn't finish. Go back to the previous
    step and run the setup again. It's safe to re-run.

## Check your email

If you sent the test alert, you'll get two emails from
`alerting-noreply@google.com` within about 5 minutes, both marked
**TEST - NOT A REAL INCIDENT**:

*   an **Error** alert for Managed Lustre;
*   a **Warning** alert for Persistent Disk.

No email after 10 minutes? Check your Spam folder, then the
[Alerting page](https://console.cloud.google.com/monitoring/alerting) for
open incidents. Test alerts close by themselves after 30 minutes.

To send another test, wait 5 minutes, then run (use a zone where you run
Managed Lustre):

```sh
cd ~/storage-samples/Managed*Lustre/Personalized*Service*Health
./scripts/send-test-events.sh PROJECT_ID us-east4-a
```

## Optional: send alerts to Slack, PagerDuty, or SMS

1.  Open the [Alerting page](https://console.cloud.google.com/monitoring/alerting).
2.  Open a policy whose name starts with **[PSH] Managed Lustre** and click
    **Edit**.
3.  Under **Notifications**, add a channel.

## Finish up

<walkthrough-conclusion-trophy></walkthrough-conclusion-trophy>

If the check said **All set** and the two test emails arrived, you're done.
From now on you'll be notified when Google Cloud posts an incident that may
affect your Managed Lustre instances.

If the check didn't say All set, go back to **Run the setup**.

*   See current and past incidents on the
    [Service Health dashboard](https://console.cloud.google.com/servicehealth/incidents).
*   To add a project or region later, run `./quickstart.sh` again. It updates
    the existing alerts.
*   To remove the alerts, run
    `./scripts/remove-lustre-psh-alerts.sh -e YOUR_EMAIL PROJECT_ID`.
