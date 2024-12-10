# Google Cloud Backup and DR Samples

The following repository provides samples for [Google Cloud Backup and DR](https://cloud.google.com/backup-disaster-recovery/docs/concepts/backup-dr).

## Google Cloud Backup and DR Samples

Check out some of the samples found on in folders of this repository. Samples include:
1. [tag-based-protection](tag-based-protection) - This sample provides a way to manage backups for your Google Compute Engine Virtual Machines (VMs) using tags. By leveraging the provided script and Google Cloud Shell, you can automate the association and removal of backup plans based on VM tags, simplifying backup management and ensuring consistent protection for your dynamic cloud environments. Note that this script only works for project level tags that are assigned to VMs, including inherited tags.

1. [project-reporting](project-reporting) - This sample provides a way to audit and report on backup protection status for your Google Compute Engine Virtual Machines (VMs). By using the provided script and Google Cloud Shell, you can generate a comprehensive report showing which VMs have backup protection and which ones don't, helping ensure compliance with your backup policies and identifying gaps in protection.
 

## Setup

1. Enable the Backup and DR Service API in your GCP Project. 

1. Clone this repository.


## Contributing

Contributions welcome! See the [Contributing Guide](CONTRIBUTING.md).
