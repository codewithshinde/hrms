To store this setup effectively, you shouldn't try to cram MariaDB and Redis into the same image. In the Docker world, the best practice is to **keep the database separate** so your data isn't lost when you update your app.

However, you can make your **Frappe image portable** so that your script and setup are baked in. Here is the best way to "store" this so you can pull it anywhere.

### 1. Create a `Dockerfile`

Currently, your code lives outside the container (mapped via `- .:/workspace`). To put it **inside** the image, create a file named `Dockerfile` in your project folder:

```dockerfile
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

```

---

### 2. Build and Push your "Custom" Image

Now, you build this into a single image that contains your logic. Replace `codewithshinde` with your Docker Hub username.

```bash
# 1. Build the image
docker build -t codewithshinde/frappe-custom:v1 .

# 2. Login
docker login

# 3. Push it to the cloud
docker push codewithshinde/frappe-custom:v1

```

---

### 3. Your New "Stored" Compose File

Now, instead of needing the `init.sh` file locally on every machine, you can just use this simplified `docker-compose.yml`. You can even store this YAML file in a **GitHub Gist** or a **Git repo**.

```yaml
version: "3.8"
services:
  mariadb:
    image: mariadb:10.8
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --skip-character-set-client-handshake
      - --skip-innodb-read-only-compressed
    environment:
      MYSQL_ROOT_PASSWORD: 123
    volumes:
      - mariadb-data:/var/lib/mysql

  redis:
    image: redis:alpine

  frappe:
    # This now pulls YOUR image with the script already inside!
    image: codewithshinde/frappe-custom:v1
    environment:
      - SHELL=/bin/bash
    ports:
      - 8000:8000
      - 9000:9000
    depends_on:
      - mariadb
      - redis

volumes:
  mariadb-data:

```

### Why this is better than a "Single Image":

1. **Data Safety:** If you put MariaDB inside the Frappe image, you will lose your database every time you restart or update the container.
2. **Standard Practice:** Using `depends_on` ensures MariaDB and Redis start before Frappe.
3. **Portability:** You only need to carry that small `docker-compose.yml` file with you. Running `docker-compose up` will pull everything else from your Docker Hub.