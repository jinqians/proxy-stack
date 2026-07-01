version: "3.8"

# PSM-managed Docker Compose project: {{PROJECT_NAME}}

services:
  {{PROJECT_NAME}}:
    image: {{IMAGE}}
    container_name: {{PROJECT_NAME}}
    restart: unless-stopped
    ports:
      - "{{LOCAL_BIND}}:{{LOCAL_PORT}}:{{CONTAINER_PORT}}"
    volumes:
      - ./data:/app/data
    environment:
      - TZ=Asia/Shanghai
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
