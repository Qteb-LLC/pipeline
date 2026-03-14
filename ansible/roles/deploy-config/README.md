# deploy-config

Ansible role for deploying application configurations from YAML files to servers with Docker Compose support.

## Description

This role:
1. Dynamically calculates the path to configuration files based on environment
2. Extracts all top-level keys from the configuration YAML file (e.g., `.env`, `docker-compose.yml`)
3. Renders each key as a separate file with value substitution from `credentials` and `endpoints`
4. Copies all files to the server
5. Authenticates to GitLab Container Registry
6. Manages Docker Compose (down, pull, up -d)

## Requirements

- SOPS installed on the control node (for credentials decryption)
- Docker and Docker Compose installed on target servers
- GitLab CI/CD environment variables for registry authentication

## Role Variables

### Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `deploy_config_name` | Name of the application | `bot` |
| `env` | Environment (test/preview/prod) | `test` |

### Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `deploy_target_path` | `/opt/{{ deploy_config_name }}` | Path on server where files will be deployed |
| `deploy_stop_before_start` | `true` | Stop containers before starting new ones |
| `deploy_local_dir` | `{{ playbook_dir }}/../deploy` | Local directory for rendered files |

### GitLab CI/CD Environment Variables

These variables are read automatically from the environment:

| Variable | Description |
|----------|-------------|
| `CI_REGISTRY` | GitLab Container Registry URL |
| `CI_REGISTRY_IMAGE` | Full image name in registry |
| `CI_REGISTRY_USER` | Registry authentication user |
| `CI_REGISTRY_PASSWORD` | Registry authentication password |
| `VERSION` | Application version (from GitVersion) |

## Configuration File Structure

The configuration file (e.g., `conf/test/bot.yaml`) should have top-level keys that represent files to be created:

```yaml
.env:
  BOT_TELEGRAM_BOT_TOKEN: {{ credentials.telegram.token }}
  BOT_DATABASE_URL: {{ endpoints.database.url }}
  # ... more environment variables

docker-compose.yml:
  services:
    bot:
      image: bot:latest  # Will be replaced with CI_REGISTRY_IMAGE:VERSION
      # ... service configuration
  volumes:
    # ...
  networks:
    # ...
```

## Directory Structure

```
conf/
  test/
    bot.yaml           # Main configuration
    credentials.yaml   # SOPS-encrypted credentials
    endpoints.yaml     # Environment-specific endpoints
  preview/
    ...
  prod/
    ...
```

## Example Playbook

```yaml
---
- name: Deploy bot configuration
  hosts: "{{ target_hosts }}"
  become: true
  roles:
    - role: deploy-config
      vars:
        deploy_config_name: bot
        deploy_target_path: /opt/bot
```

## Usage with GitLab CI/CD

```yaml
deploy:test:
  stage: deploy
  script:
    - ansible-playbook -i ansible/inventory.yaml ansible/play.yml \
        -e "env=test target_hosts=test_nodes"
```

## License

MIT
