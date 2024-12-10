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