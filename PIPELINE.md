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

---

## Анализ: адаптация под мультирепо

### Текущее распределение по репозиториям

| Что | Где было (монорепо) | Где сейчас |
|-----|-------------------|------------|
| Workflow-файлы | `.github/workflows/` | `Qteb-LLC/pipeline` |
| Composite action | `.github/actions/setup-python-uv/` | `Qteb-LLC/pipeline` |
| `ansible/`, `utils/`, `conf/` | корень монорепо | `Qteb-LLC/conf` |
| `docker/Dockerfile` (bot) | `docker/Dockerfile` | `Qteb-LLC/bot/docker/Dockerfile` |
| `docker/Dockerfile.api` | `docker/Dockerfile.api` | `Qteb-LLC/api/docker/Dockerfile.api` |
| `front/Dockerfile` | `front/Dockerfile` | `Qteb-LLC/web/Dockerfile` |
| `GitVersion.yml` | корень монорепо | в каждом code-репо |
| Исходный код bot | `src/` | `Qteb-LLC/bot` |
| Исходный код api | `src/` | `Qteb-LLC/api` |
| Исходный код web | `front/` | `Qteb-LLC/web` |

### Проблема 1: Локальные ссылки между workflows

**Что сломано:**

Workflow `build.yml` вызывает:
```yaml
uses: ./.github/workflows/version.yml
uses: ./.github/workflows/lint-test.yml
uses: ./.github/workflows/deploy.yml
```

В мультирепо code-репо (например, `Qteb-LLC/api`) вызывает workflow из pipeline-репо:
```yaml
uses: Qteb-LLC/pipeline/.github/workflows/build.yml@main
```

При этом `build.yml` выполняется в контексте вызывающего репо (`api`). Ссылка `uses: ./.github/workflows/version.yml` будет искать `version.yml` в `api`-репо, а не в `pipeline`-репо — **файла там нет, workflow упадёт.**

**Затронуты:**
- `build.yml` → ссылается на `version.yml`, `lint-test.yml`, `deploy.yml`
- `deploy-tag.yml` → ссылается на `version.yml`, `lint-test.yml`, `deploy.yml`
- `release.yml` → ссылается на `version.yml`

**Что нужно сделать:**

Заменить все внутренние ссылки на абсолютные:
```yaml
# Было (монорепо)
uses: ./.github/workflows/version.yml

# Нужно (мультирепо)
uses: Qteb-LLC/pipeline/.github/workflows/version.yml@main
```

### Проблема 2: Composite action — локальная ссылка

**Что сломано:**

`lint-test.yml` использует:
```yaml
uses: ./.github/actions/setup-python-uv
```

Когда `lint-test.yml` вызывается кросс-репо, `.` указывает на вызывающий репо — action там нет.

**Затронуты:**
- `lint-test.yml` — 4 job'а ссылаются на `./.github/actions/setup-python-uv`

**Что нужно сделать:**

Заменить на абсолютную ссылку:
```yaml
# Было
uses: ./.github/actions/setup-python-uv

# Нужно
uses: Qteb-LLC/pipeline/.github/actions/setup-python-uv@main
```

### Проблема 3: deploy.yml — checkout не того репо

**Что сломано:**

`deploy.yml` делает:
```yaml
- uses: actions/checkout@v4
```

Это чекаутит вызывающий репо (code-репо). Но deploy ожидает файлы, которые теперь в `Qteb-LLC/conf`:
- `ansible/inventory.yaml`, `ansible/play.yml`, `ansible/requirements.yml`
- `utils/decrypt.sh`
- `conf/{environment}/id_rsa`

**Что нужно сделать:**

Заменить checkout на checkout `Qteb-LLC/conf`:
```yaml
- uses: actions/checkout@v4
  with:
    repository: Qteb-LLC/conf
    token: ${{ secrets.CONF_PAT || github.token }}
```

Также нужен PAT (`CONF_PAT`) или deploy key, т.к. `conf` — приватный репозиторий, а `GITHUB_TOKEN` из вызывающего репо не имеет доступа к другому репозиторию.

### Проблема 4: build.yml и deploy-tag.yml — монолитная сборка

**Что сломано:**

`build.yml` содержит два job'а сборки:
- `build` — собирает bot из `docker/Dockerfile`
- `build-web` — собирает web из `front/Dockerfile`

В мультирепо каждый сервис — отдельный репозиторий. Не нужно собирать web, когда пушим в bot.

**Что нужно сделать:**

Два варианта:

**Вариант A:** Оставить `build.yml` и `deploy-tag.yml` как trigger-шаблоны, но **не вызывать их кросс-репо**. Вместо этого каждый code-репо имеет свой `.github/workflows/pr.yml` и `deploy-tag.yml`, которые вызывают отдельные reusable workflows (`version.yml`, `lint-test.yml`, `deploy.yml`).

**Вариант B:** Переделать `build.yml` в reusable workflow с параметрами `dockerfile`, `context`, `image-suffix` и убрать job `build-web`.

Рекомендуется **вариант A** — trigger workflows живут в code-репо, reusable workflows (version, lint-test, deploy) живут в pipeline. Причина: trigger workflows содержат бизнес-логику конкретного сервиса (какой Dockerfile, какие build args, deploy preview или нет), и эта логика у каждого сервиса своя.

При варианте A из pipeline-репо **удаляются** `build.yml` и `deploy-tag.yml` (они становятся ненужными), а сборка Docker выносится в отдельный reusable workflow.

### Проблема 5: lint-test.yml — только Python

**Что сломано:**

`lint-test.yml` запускает ruff + mypy + pytest. Для `Qteb-LLC/web` (Node.js) нужен другой pipeline: lint + build.

**Что нужно сделать:**

Создать `lint-test-node.yml` (или `ci-node.yml`) с:
- `npm ci`
- `npm run lint`
- `npm run build`

### Проблема 6: lint-test.yml — test job зависимости

**Что сломано:**

Job `test` в `lint-test.yml` поднимает PostgreSQL service container и устанавливает env-переменные:
```yaml
BOT_DATABASE_HOST, BOT_DATABASE_PORT, BOT_DATABASE_NAME, ...
BOT_TELEGRAM_BOT_TOKEN, BOT_LITELLM_*, BOT_CLOUDPAYMENTS_*
```

Эти переменные специфичны для API-репо. Bot-репо не использует PostgreSQL, и ему не нужны `BOT_DATABASE_*` переменные.

**Что нужно сделать:**

Параметризовать `lint-test.yml`:
- Input `needs-postgres` (boolean, default true) — запускать ли PostgreSQL service
- Input `env-vars` или передавать через secrets — какие env-переменные нужны

Или: разделить на `lint.yml` (ruff + mypy, без зависимостей) и `test.yml` (pytest, с настраиваемыми сервисами).

### Проблема 7: version.yml — GitVersion.yml

**Что сломано:**

`version.yml` использует:
```yaml
useConfigFile: true
configFilePath: GitVersion.yml
```

`GitVersion.yml` ожидается в корне **вызывающего** репо (т.к. checkout делает вызывающий репо). Каждый code-репо должен иметь свой `GitVersion.yml`.

**Что нужно сделать:**

Каждый code-репо (`bot`, `api`, `web`) должен содержать `GitVersion.yml` в корне. Содержимое может быть одинаковым — скопировать из монорепо.

### Итого: план доработок

| # | Файл | Изменение | Тип |
|---|------|-----------|-----|
| 1 | `lint-test.yml` | Заменить `uses: ./.github/actions/setup-python-uv` → абсолютный путь | Ссылки |
| 2 | `lint-test.yml` | Добавить inputs для параметризации (postgres, env vars) | Параметризация |
| 3 | `deploy.yml` | Checkout `Qteb-LLC/conf` вместо вызывающего репо | Checkout |
| 4 | `release.yml` | Заменить `uses: ./.github/workflows/version.yml` → абсолютный путь | Ссылки |
| 5 | `build.yml` | Удалить (заменяется reusable `build-docker.yml`) | Удаление |
| 6 | `deploy-tag.yml` | Удалить (trigger-логика переезжает в code-репо) | Удаление |
| 7 | Новый `build-docker.yml` | Reusable: параметризованная сборка Docker image | Новый |
| 8 | Новый `ci-node.yml` | Reusable: lint + build для Node.js | Новый |
| 9 | Каждый code-репо | Добавить `GitVersion.yml` | Конфиг |
| 10 | Каждый code-репо | Добавить trigger workflows (`pr.yml`, `release.yml`, `deploy-tag.yml`) | Callers |

### Что остаётся в pipeline-репо (после доработок)

```
.github/
├── actions/
│   └── setup-python-uv/action.yml    # Без изменений
└── workflows/
    ├── version.yml        # Без изменений (уже reusable)
    ├── lint-test.yml      # Доработка: абсолютные ссылки, параметризация
    ├── ci-node.yml        # Новый: Node.js CI
    ├── build-docker.yml   # Новый: параметризованная Docker сборка
    ├── deploy.yml         # Доработка: checkout Qteb-LLC/conf
    └── release.yml        # Доработка: абсолютные ссылки
```

`build.yml` и `deploy-tag.yml` удаляются — их логика переезжает в trigger workflows в каждом code-репо.

### Что появляется в каждом code-репо

```
# Qteb-LLC/bot, Qteb-LLC/api
.github/workflows/
├── pr.yml           # on: pull_request → version + lint-test + build-docker + deploy preview
├── release.yml      # on: push main → release (создать тег)
└── deploy-tag.yml   # on: push tag → lint-test + build-docker + deploy preview + prod
GitVersion.yml       # Конфиг GitVersion

# Qteb-LLC/web
.github/workflows/
├── pr.yml           # on: pull_request → version + ci-node + build-docker + deploy preview
├── release.yml      # on: push main → release
└── deploy-tag.yml   # on: push tag → ci-node + build-docker + deploy preview + prod
GitVersion.yml
```
