# Use the base image you were already using
FROM frappe/bench:latest

# Set the working directory
WORKDIR /home/frappe

# Copy your init.sh script into the image
COPY init.sh /home/frappe/init.sh

# Give execution permissions to the script
USER root
RUN chmod +x /home/frappe/init.sh
USER frappe

# This ensures when the container starts, it runs your script
ENTRYPOINT ["/bin/bash", "/home/frappe/init.sh"]