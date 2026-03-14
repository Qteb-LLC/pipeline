# Pipeline — эталонная документация

Этот документ описывает текущую логику CI/CD pipeline **как она есть** в оригинальных workflow-файлах.
Является эталоном для самопроверки при адаптации под мультирепо-архитектуру.

## Общая архитектура

Pipeline состоит из 6 workflow-файлов и 1 composite action:

```
.github/
├── actions/
│   └── setup-python-uv/action.yml    # Composite: Python + uv + кэширование
└── workflows/
    ├── version.yml      # Reusable: вычисление SemVer через GitVersion
    ├── lint-test.yml    # Reusable: ruff + mypy + pytest (с PostgreSQL)
    ├── build.yml        # Trigger: PR → lint + build Docker + deploy preview
    ├── release.yml      # Trigger: push main → создать Git tag + GitHub Release
    └── deploy-tag.yml   # Trigger: push tag → lint + build Docker + deploy preview + prod
    └── deploy.yml       # Reusable: деплой через Ansible + SOPS
```

## Жизненный цикл изменений

### 1. Pull Request → Preview

**Триггер:** `on: pull_request`
**Файл:** `build.yml`

```
PR открыт/обновлён
  │
  ├─ version (parallel) ─── GitVersion вычисляет semver из ветки PR
  ├─ lint-test (parallel) ── ruff-check, ruff-format, mypy, pytest (4 параллельных jobs)
  │
  ├─ build (after version + lint-test) ── Docker build bot image → push GHCR
  │     Теги: {semver}, {sha}, latest
  │
  ├─ build-web (after version + lint-test) ── Docker build web image → push GHCR
  │     Условие: только если изменены файлы в front/
  │     Теги: {semver}, {sha}, latest
  │     Build args: NEXT_PUBLIC_BOT_USERNAME, NEXT_PUBLIC_API_URL (из secrets)
  │
  └─ deploy-preview (after build + build-web) ── Ansible deploy на preview-окружение
```

**Детали build job:**
- Docker registry: `ghcr.io`
- Image name: `ghcr.io/{owner}/{repo}` (lowercase)
- Web image name: `ghcr.io/{owner}/{repo}/web`
- Dockerfile bot: `docker/Dockerfile`
- Dockerfile web: `front/Dockerfile`, context: `front`
- Cache: `type=registry` с fallback на `:latest`

### 2. Merge в main → Release

**Триггер:** `on: push: branches: [main]`
**Файл:** `release.yml`

```
Push в main (merge PR)
  │
  ├─ version ── GitVersion вычисляет semver из main
  │
  └─ release (after version)
        ├─ Checkout с PAT (RELEASE_PAT, fallback GITHUB_TOKEN)
        ├─ Извлечь changelog notes из CHANGELOG.md (если есть)
        └─ Создать GitHub Release + Git tag: {semver}
           Token: RELEASE_PAT (чтобы tag trigger сработал)
```

**Важно:** Используется `RELEASE_PAT` (Personal Access Token), потому что теги, созданные с `GITHUB_TOKEN`, не триггерят другие workflows. PAT нужен, чтобы созданный тег запустил `deploy-tag.yml`.

### 3. Tag → Build + Deploy (Preview + Prod)

**Триггер:** `on: push: tags: ['*']`
**Файл:** `deploy-tag.yml`

```
Git tag создан (из release.yml)
  │
  ├─ version (parallel) ─── GitVersion из тега
  ├─ lint-test (parallel) ── ruff-check, ruff-format, mypy, pytest
  │
  ├─ build (after version + lint-test) ── Docker build bot → push GHCR
  │     Теги: {tag_name}, {sha}, latest
  │
  ├─ build-web (after version + lint-test) ── Docker build web → push GHCR
  │     Условие: только если front/ существует
  │     Теги: {tag_name}, {sha}, latest
  │
  ├─ deploy-preview (after build + build-web)
  │     └─ Ansible deploy на preview
  │
  └─ deploy-prod (after build + build-web)
        └─ Ansible deploy на prod
```

**Отличия от PR pipeline:**
- Теги Docker image: `{tag_name}` вместо `{semver}` (tag_name = ref_name)
- Web build: проверяет существование `front/` (не diff), т.к. нет base SHA
- Деплой и на preview, и на prod (в PR — только preview)

### 4. Полная цепочка (от PR до прода)

```
Developer creates PR
      │
      ▼
  [build.yml] PR pipeline
      ├─ lint-test ✓
      ├─ build Docker images ✓
      └─ deploy preview ✓
      │
      ▼
  PR merged to main
      │
      ▼
  [release.yml] Auto-release
      └─ Create tag "0.3.1" + GitHub Release
      │
      ▼
  Tag "0.3.1" pushed
      │
      ▼
  [deploy-tag.yml] Tag pipeline
      ├─ lint-test ✓ (повторно, safety net)
      ├─ build Docker images ✓ (с tag-based тегами)
      ├─ deploy preview ✓
      └─ deploy prod ✓
```

## Reusable workflows (детали)

### version.yml

**Тип:** `workflow_call`
**Inputs:** `branch` (optional, string)
**Outputs:** `semver` (string)

- Checkout с `fetch-depth: 0` (полная история для GitVersion)
- GitVersion 5.x, конфиг из `GitVersion.yml` (в корне вызывающего репозитория)
- Для PR: передаётся `branch: ${{ github.head_ref }}`
- Для main/tag: branch не передаётся (используется `github.ref`)

### lint-test.yml

**Тип:** `workflow_call`
**Inputs:** нет

4 параллельных jobs:
1. **ruff-check** — `ruff check src/ tests/`
2. **ruff-format** — `ruff format --check src/ tests/`
3. **mypy** — `mypy src/`
4. **test** — `pytest --cov=src --cov-report=xml --cov-report=term`

**test job особенности:**
- Поднимает PostgreSQL 16 service container
- Env-переменные для тестовой БД: `BOT_DATABASE_*`
- Env-переменные для обязательных настроек: `BOT_TELEGRAM_BOT_TOKEN`, `BOT_LITELLM_*`, `BOT_CLOUDPAYMENTS_*`
- Coverage report загружается как artifact

**setup-python-uv action:**
- Python 3.13 (по умолчанию)
- `uv` для установки зависимостей
- Кэширование `.cache/pip`, `.cache/uv`, `.venv/`
- `pip install -e ".[dev]"` — editable install с dev-зависимостями
- venv добавляется в PATH

### deploy.yml

**Тип:** `workflow_call`
**Inputs:** `environment` (string, required), `version` (string, required)

Шаги:
1. **Checkout** текущего репозитория (для доступа к `ansible/`, `utils/`, `conf/`)
2. **Cache** ansible roles + sops binary
3. **Setup tools:** ansible, sops 3.9.2, ansible-galaxy roles + collections
4. **Decrypt secrets:**
   - Vault key из GitHub secrets (`ANSIBLE_VAULT_KEY_PREVIEW` или `ANSIBLE_VAULT_KEY_PROD`)
   - Записывается в `utils/{env}_vault.key`
   - Запуск `utils/decrypt.sh`
5. **Ansible playbook:**
   - Inventory: `ansible/inventory.yaml`
   - Playbook: `ansible/play.yml`
   - SSH key: `conf/{environment}/id_rsa`
   - Переменные: `env={environment}`
   - CI_REGISTRY_IMAGE: `ghcr.io/{owner}/{repo}` (lowercase)
   - VERSION: переданная версия

**Environment URLs:**
- preview: `https://t.me/mimir_preview_robot`
- prod: `https://t.me/mimir_robot`

**Зависимости от файлов (ожидает в текущем репо):**
- `ansible/inventory.yaml`
- `ansible/play.yml`
- `ansible/requirements.yml`
- `utils/decrypt.sh`
- `conf/{environment}/id_rsa`

## Секреты (GitHub Secrets)

| Secret | Где используется | Описание |
|--------|-----------------|----------|
| `GITHUB_TOKEN` | build, deploy | Автоматический, доступ к GHCR и API |
| `RELEASE_PAT` | release | PAT для создания тегов (триггерит deploy-tag) |
| `ANSIBLE_VAULT_KEY_PREVIEW` | deploy | Ключ для расшифровки preview-конфигов |
| `ANSIBLE_VAULT_KEY_PROD` | deploy | Ключ для расшифровки prod-конфигов |
| `NEXT_PUBLIC_BOT_USERNAME` | build-web | Telegram bot username для фронтенда |
| `NEXT_PUBLIC_API_URL` | build-web | API URL для фронтенда |

## Docker images

| Image | Registry | Dockerfile | Context |
|-------|----------|------------|---------|
| Bot/API | `ghcr.io/{owner}/{repo}` | `docker/Dockerfile` | `.` |
| Web | `ghcr.io/{owner}/{repo}/web` | `front/Dockerfile` | `front` |

**Тегирование:**
- PR: `{semver}`, `{sha}`, `latest`
- Tag: `{tag_name}`, `{sha}`, `latest`

## Concurrency

- `build.yml`: group `build-{ref}`, cancel-in-progress
- `release.yml`: group `release-{ref}`, cancel-in-progress
- `deploy-tag.yml`: нет concurrency (каждый тег обрабатывается)

## Ограничения текущей реализации (монорепо)

1. **Локальные ссылки** — `uses: ./.github/workflows/...` работает только внутри одного репо
2. **Composite action** — `uses: ./.github/actions/setup-python-uv` — тоже только локально
3. **deploy.yml** — `uses: actions/checkout@v4` чекаутит вызывающий репо, ожидает `ansible/`, `utils/`, `conf/` в нём
4. **build.yml** — захардкожены `docker/Dockerfile` и `front/Dockerfile`, `build-web` привязан к `front/`
5. **lint-test.yml** — Python-специфичный, для web (Node.js) нет аналога
6. **version.yml** — ожидает `GitVersion.yml` в корне вызывающего репо
7. **Один bot+web image** — оба собираются в одном pipeline, привязаны к одному репо
