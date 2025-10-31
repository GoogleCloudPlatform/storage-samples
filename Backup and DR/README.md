# Google Cloud Backup and DR Samples

The following repository provides samples for [Google Cloud Backup and DR](https://cloud.google.com/backup-disaster-recovery/docs/concepts/backup-dr).

## Google Cloud Backup and DR Samples

Check out some of the samples found on in folders of this repository. Samples include:
1. [tag-based-protection](tag-based-protection) - This sample provides a way to manage backups for your Google Compute Engine Virtual Machines (VMs) using tags. By leveraging the provided script and Google Cloud Shell, you can automate the association and removal of backup plans based on VM tags, simplifying backup management and ensuring consistent protection for your dynamic cloud environments. Note that this script only works for project level tags that are assigned to VMs, including inherited tags.

1. [project-reporting](project-reporting) - This sample provides a way to audit and report on backup protection status for your Google Compute Engine Virtual Machines (VMs). By using the provided script and Google Cloud Shell, you can generate a comprehensive report showing which VMs have backup protection and which ones don't, helping ensure compliance with your backup policies and identifying gaps in protection.

1. [cloud-run-scheduler](cloud-run-scheduler) -  Read how to set up a Cloud Run Job in Google Cloud Platform to set up your Tag Based Protection script to run on an hourly, daily, weekly or monthly basis.

1. [protection-summary](protection-summary) -  This script provides a way to bulk protect all your unprotected instances. An [unprotected instance](https://cloud.google.com/backup-disaster-recovery/docs/backup-admin/protection-summary?_gl=1*1tsvrak*_ga*NzkzNTI2MzUuMTczOTQwNjczNQ..*_ga_WH2QY8WWF5*MTczOTQwNDU4Ni42LjEuMTczOTQwOTczNC40OC4wLjA.) is an instance that has no active backup plan or snapshot schedule attached to the VM instance.

1. [list-protection-summary](list-protection-summary) - Protection summary, a new capability in the Google Cloud Backup and DR management experience, allows you to view the backup configuration state of your resources. Protection summary helps you to easily identify resources that have not been configured for backup, discover those that are configured and identify areas where you can enhance your data protection.
   Using this script you can easily get the protection summary information across one or more projects, folders or organizations. Using the script you can get information about all unprotected workloads in a single shot or what was the last succesful backup time.

1. [analyze_dup_backup_configs](analyze_dup_backup_configs) - This script helps analyze GCE VMs having duplicate backup configuration. It helps by listing all GCE VMs having both BackupDR SLT and Backup Plan applied across multiple projects or folders or orgs not limited to a single region using a Bash script named analyze_dup_backup_configs.sh. This script leverages the [Backup and DR Protection Summary](https://cloud.google.com/backup-disaster-recovery/docs/backup-admin/protection-summary?_gl=1*1tsvrak*_ga*NzkzNTI2MzUuMTczOTQwNjczNQ..*_ga_WH2QY8WWF5*MTczOTQwNDU4Ni42LjEuMTczOTQwOTczNC40OC4wLjA.) feature.
   
## Setup

1. Enable the Backup and DR Service API in your GCP Project. 

1. Clone this repository.


## Contributing

Contributions welcome! See the [Contributing Guide](CONTRIBUTING.md).
