# CLAUDE.md — MimirAI Pipeline

Это руководство для Claude Code по работе с CI/CD-инфраструктурой MimirAI.

## Обзор

Pipeline — репозиторий CI/CD-оркестрации для мультирепо-архитектуры MimirAI. Содержит reusable GitHub Actions workflows, Ansible-плейбуки для деплоя и конфигурации окружений. Код-репозитории (bot, api, web) вызывают workflows из этого репозитория.

## Структура

```
pipeline/
├── .github/
│   ├── actions/
│   │   └── setup-python-uv/action.yml    # Composite: Python 3.13 + uv + кеширование
│   └── workflows/
│       ├── version.yml           # Reusable: SemVer через GitVersion
│       ├── lint-test.yml         # Reusable: ruff + mypy + pytest (с PostgreSQL 16)
│       ├── release.yml           # Reusable: GitHub Release + Git tag
│       ├── deploy.yml            # Reusable: Ansible-деплой + SOPS
│       ├── publish-python.yml    # Reusable: Docker build Python-сервисов
│       ├── publish-web.yml       # Reusable: Docker build Next.js
│       ├── backend-pr.yml        # Reusable: PR-pipeline для Python
│       ├── backend-release.yml   # Reusable: Release-pipeline для Python
│       ├── backend-tag.yml       # Reusable: Tag/deploy для Python
│       ├── frontend-pr.yml       # Reusable: PR-pipeline для Web
│       ├── frontend-release.yml  # Reusable: Release-pipeline для Web
│       └── frontend-tag.yml      # Reusable: Tag/deploy для Web
├── ansible/
│   ├── play.yml                  # Основной плейбук: Docker + deploy-config
│   ├── inventory.yaml            # Хосты: local, preview, prod
│   ├── requirements.yml          # geerlingguy.docker, community.docker
│   └── roles/deploy-config/      # Роль деплоя: рендеринг конфигов + Docker
├── conf/
│   ├── local/docker-compose.yml  # Dev: bot + api + postgres + redis
│   ├── preview/docker-compose.yml # Staging: + web + traefik + Let's Encrypt
│   └── prod/docker-compose.yml   # Production: + web + traefik + Let's Encrypt
├── utils/
│   ├── decrypt.sh                # SOPS/Ansible Vault расшифровка
│   ├── check-sops.sh             # Валидация SOPS-шифрования
│   └── importpgp.sh              # Импорт PGP-ключей
├── GitVersion.yml                # Конфигурация SemVer (ContinuousDelivery)
├── .sops.yaml                    # Правила шифрования для conf/{env}/
└── PIPELINE.md                   # Детальная документация pipeline
```

## Обслуживаемые сервисы

| Сервис | Репозиторий | Тип |
|--------|-----------|-----|
| Bot | `Qteb-LLC/bot` | Python, aiogram |
| API | `Qteb-LLC/api` | Python, FastAPI |
| Web | `Qteb-LLC/web` | TypeScript, Next.js |

## Жизненный цикл изменений

### 1. Pull Request → Preview

```
PR открыт/обновлён
  ├─ version (parallel) ─── GitVersion → semver
  ├─ lint-test (parallel) ── ruff, mypy, pytest (4 jobs)
  ├─ build (after version + lint-test) ── Docker build → push GHCR
  └─ deploy-preview (after build) ── Ansible → preview-сервер
```

### 2. Merge в main → Release

```
Push в main
  ├─ version ── GitVersion → semver
  └─ release ── GitHub Release + Git tag (через RELEASE_PAT)
```

### 3. Tag → Build + Deploy (Preview + Prod)

```
Tag создан
  ├─ version + lint-test (parallel)
  ├─ build (after lint-test)
  ├─ deploy-preview (after build)
  └─ deploy-prod (after build)
```

## Reusable Workflows

### version.yml
- **Вход:** `branch` (optional)
- **Выход:** `semver` (string)
- Использует GitVersion 5.x с `GitVersion.yml` из вызывающего репо

### lint-test.yml
4 параллельных job:
1. `ruff-check` — `ruff check src/ tests/`
2. `ruff-format` — `ruff format --check src/ tests/`
3. `mypy` — `mypy src/`
4. `test` — `pytest` с PostgreSQL 16 service container

### deploy.yml
- **Вход:** `environment` (string), `version` (string)
- Checkout сервисного репо + pipeline-репо
- Расшифровка секретов (SOPS + Ansible Vault)
- Ansible playbook: установка Docker, рендеринг конфигов, docker compose up

### publish-python.yml / publish-web.yml
- Docker build + push в `ghcr.io`
- Теги: `{version}`, `{sha}`, `latest`
- Web: build args `NEXT_PUBLIC_BOT_USERNAME`, `NEXT_PUBLIC_API_URL`

## Окружения

| Окружение | Хост | URL |
|-----------|------|-----|
| local | localhost | — |
| preview | bot-preview.mimirai.ru | `https://t.me/mimir_preview_robot` |
| prod | bot-prod.mimirai.ru | `https://t.me/mimir_robot` |

## Docker Compose сервисы

### Local
`bot`, `api`, `postgres`, `redis`

### Preview / Prod
`bot`, `api`, `web`, `postgres`, `redis`, `traefik` (TLS через Let's Encrypt), `migrations` (init-контейнер)

## Секреты (GitHub Secrets)

| Secret | Назначение |
|--------|-----------|
| `GITHUB_TOKEN` | Доступ к GHCR и API |
| `RELEASE_PAT` | PAT для создания тегов (триггерит deploy-tag) |
| `ANSIBLE_VAULT_KEY_PREVIEW` | Ключ расшифровки preview-конфигов |
| `ANSIBLE_VAULT_KEY_PROD` | Ключ расшифровки prod-конфигов |
| `NEXT_PUBLIC_BOT_USERNAME` | Telegram bot username для фронтенда |
| `NEXT_PUBLIC_API_URL` | API URL для фронтенда |

## Шифрование

- SOPS с PGP-ключами для шифрования конфигов в `conf/{env}/`
- Ansible Vault для дополнительной защиты секретов
- Ключи: `conf/{env}/pgp.key` + `conf/{env}/pgp.pub`

## Версионирование

GitVersion в режиме `ContinuousDelivery`:
- Feature-ветки → Minor bump
- Bugfix-ветки → Patch bump
- Коммит-сообщения: `+semver: breaking|major|minor|feature|fix|patch`

## Вызов из код-репозиториев

Код-репо вызывают workflows через абсолютные ссылки:

```yaml
jobs:
  lint-test:
    uses: Qteb-LLC/pipeline/.github/workflows/lint-test.yml@main
  build:
    uses: Qteb-LLC/pipeline/.github/workflows/publish-python.yml@main
  deploy:
    uses: Qteb-LLC/pipeline/.github/workflows/deploy.yml@main
    with:
      environment: preview
      version: ${{ needs.version.outputs.semver }}
```

## Ansible

Основной плейбук (`ansible/play.yml`):
1. Установка Docker (роль `geerlingguy.docker`)
2. Роль `deploy-config`: рендеринг конфигов из шаблонов, merge shared + env-specific
3. Docker Compose pull + up

Inventory (`ansible/inventory.yaml`): группы `local`, `preview`, `prod` с соответствующими хостами.
