# Гид по Конфигурации

Полное описание всех конфигурационных файлов и переменных платформы GitOpsLab.

---

## 📁 Конфигурационные Файлы

| Файл | Назначение |
|------|-----------|
| `.env` | Главный конфиг — переменные окружения |
| `docker-compose.yml` | Определение Docker-сервисов |
| `.woodpecker.yml` | Конфигурация CI pipeline |
| `scripts/registries.yaml` | Insecure registries для k3d |
| `gitops/argocd/root-app.yaml` | Root Application для Argo CD |

---

## 1. Главный Конфиг (.env)

Файл `.env` содержит все настройки платформы. Создаётся автоматически из `.env.example` при первом запуске.

### Core

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `COMPOSE_PROJECT_NAME` | `gitopslab` | Префикс для Docker-ресурсов |

### Gitea

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `GITEA_VERSION` | `1.21.11` | Версия образа Gitea |
| `GITEA_HTTP_PORT` | `3000` | HTTP порт (host) |
| `GITEA_SSH_PORT` | `2222` | SSH порт (host) |
| `GITEA_ADMIN_USER` | `gitops` | Имя администратора |
| `GITEA_ADMIN_PASSWORD` | `gitops1234` | Пароль администратора |
| `GITEA_INTERNAL_URL` | `http://gitea:3000` | Внутренний URL (для контейнеров) |
| `GITEA_K3D_URL` | `http://10.88.0.1:3000` | URL для k3d кластера |
| `GITEA_PUBLIC_URL` | `http://gitea.localhost:3000` | Публичный URL (для браузера) |

### Woodpecker

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `WOODPECKER_VERSION` | `v3.12.0` | Версия Woodpecker |
| `WOODPECKER_SERVER_PORT` | `8000` | HTTP порт (host) |
| `WOODPECKER_AGENT_SECRET` | `supersecret` | Секрет для агента |
| `WOODPECKER_ADMIN` | `gitops` | Администратор |
| `WOODPECKER_GITEA_CLIENT` | *auto* | OAuth Client ID (генерируется) |
| `WOODPECKER_GITEA_SECRET` | *auto* | OAuth Client Secret (генерируется) |
| `WOODPECKER_HOST` | `http://woodpecker.localhost:8000` | Публичный URL |
| `WOODPECKER_INTERNAL_URL` | `http://woodpecker-server:8000` | Внутренний URL |
| `WOODPECKER_GITEA_URL` | `http://gitea:3000` | URL Gitea для OAuth |
| `WOODPECKER_EXPERT_FORGE_OAUTH_HOST` | `http://gitea.localhost:3000` | OAuth host |
| `WOODPECKER_EXPERT_WEBHOOK_HOST` | `http://woodpecker-server:8000` | Webhook host |

### Argo CD

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `ARGOCD_VERSION` | `2.10.7` | Версия Argo CD |
| `ARGOCD_PORT` | `8081` | HTTP порт (host через NodePort) |
| `ARGOCD_PUBLIC_URL` | `http://argocd.localhost:8081` | Публичный URL |

### MLflow

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `MLFLOW_PORT` | `8090` | HTTP порт (host) |
| `MLFLOW_PUBLIC_URL` | `http://mlflow.localhost:8090` | Публичный URL |
| `MLFLOW_EXPERIMENT_NAME` | `hello-api-training` | Имя эксперимента |

### MinIO

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `MINIO_API_PORT` | `9090` | API порт (host) |
| `MINIO_CONSOLE_PORT` | `9091` | Console порт (host) |
| `MINIO_PUBLIC_URL` | `http://minio.localhost:9090` | API URL |
| `MINIO_CONSOLE_URL` | `http://minio.localhost:9091` | Console URL |
| `MINIO_ROOT_USER` | `minioadmin` | Пользователь |
| `MINIO_ROOT_PASSWORD` | `minioadmin123` | Пароль |

### k3d / Bootstrap

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `K3D_CLUSTER_NAME` | `gitopslab` | Имя кластера |
| `K3D_API_PORT` | `6550` | K8s API порт (host) |
| `K3D_REGISTRY_NAME` | `registry.localhost` | Имя registry |
| `K3D_REGISTRY_PORT` | `5002` | Registry порт (host) |
| `K3D_NETWORK` | `podman` | Docker-сеть для k3d |
| `DOCKER_SOCKET` | `/run/podman/podman.sock` | Путь к Docker socket |
| `HOST_GATEWAY_IP` | `10.89.0.1` | IP gateway (auto-detected) |

### Demo Application

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `DEMO_PUBLIC_URL` | `http://demo.localhost:8088` | URL demo-приложения |
| `HELLO_API_IMAGE` | `registry.localhost:5002/hello-api` | Образ Hello API |
| `HELLO_API_VERSION` | `dev` | Тег образа |

---

## 2. Docker Compose (docker-compose.yml)

### Сервисы

| Сервис | Образ | Назначение |
|--------|-------|-----------|
| `gitea` | `gitea/gitea` | Git-сервер |
| `woodpecker-server` | `woodpeckerci/woodpecker-server` | CI-сервер |
| `woodpecker-agent` | `woodpeckerci/woodpecker-agent` | CI-агент |
| `bootstrap` | `./bootstrap` | Инициализация платформы |

### Volumes

| Volume | Назначение |
|--------|-----------|
| `gitea-data` | Данные Gitea (репозитории, БД) |
| `woodpecker-data` | Данные Woodpecker (SQLite БД) |

### Networks

| Сеть | Назначение |
|------|-----------|
| `k3d` | Внешняя сеть (создаётся k3d) |

### Extra Hosts

Все контейнеры получают extra_hosts для split-horizon DNS:

```yaml
extra_hosts:
  - "gitea.localhost:${HOST_GATEWAY_IP}"
  - "woodpecker.localhost:${HOST_GATEWAY_IP}"
  - "argocd.localhost:${HOST_GATEWAY_IP}"
  - "demo.localhost:${HOST_GATEWAY_IP}"
  - "minio.localhost:${HOST_GATEWAY_IP}"
  - "mlflow.localhost:${HOST_GATEWAY_IP}"
```

---

## 3. Pipeline (.woodpecker.yml)

### Clone Configuration

```yaml
clone:
  git:
    image: woodpeckerci/plugin-git
    settings:
      remote: http://gitea:3000/${CI_REPO}.git
      branch: main
```

### Steps

| Step | Образ | Назначение |
|------|-------|-----------|
| `test` | `python:3.10-slim` | pytest для Hello API |
| `train-model` | `python:3.10-slim` | Обучение ML-модели |
| `upload-model` | `minio/mc:latest` | Загрузка модели в MinIO |
| `build` | `docker:24.0-cli` | Сборка и push образа |
| `scan` | `aquasec/trivy` | Сканирование уязвимостей |
| `update-gitops` | `alpine/git` | Обновление манифестов |

### Секреты

| Секрет | Используется в | Описание |
|--------|----------------|----------|
| `gitea_user` | `update-gitops` | Логин для git push |
| `gitea_token` | `update-gitops` | Токен для git push |

### Переменные окружения Pipeline

| Переменная | Значение | Описание |
|------------|----------|----------|
| `MLFLOW_TRACKING_URI` | `http://10.89.0.1:8090` | URL MLflow |
| `MINIO_ENDPOINT` | `http://10.89.0.1:9090` | URL MinIO API |
| `DOCKER_HOST` | `tcp://10.89.0.1:2375` | Docker API |

> [!IMPORTANT]
> IP-адрес `10.89.0.1` — это gateway сети k3d. Он может отличаться на вашей системе (проверьте `HOST_GATEWAY_IP` в `.env`).

### Triggers

```yaml
when:
  event: [push, manual]
  message:
    exclude:
      - '^chore\(e2e\):'
      - '^chore: sync workspace into Gitea'
```

Pipeline запускается на `push` и `manual` триггеры, исключая служебные коммиты.

---

## 4. GitOps Манифесты (gitops/)

### Структура

```
gitops/
├── argocd/
│   └── root-app.yaml           # Root Application (App of Apps)
└── apps/
    ├── hello-application.yaml   # ArgoCD App для Hello API
    ├── hello/
    │   ├── deployment.yaml      # ← Обновляется pipeline
    │   ├── service.yaml
    │   ├── ingress.yaml
    │   └── model-configmap.yaml # ← Обновляется pipeline
    ├── mlflow-application.yaml
    ├── mlflow/
    │   ├── deployment.yaml
    │   ├── service.yaml
    │   └── ...
    ├── minio-application.yaml
    ├── minio/
    │   └── ...
    ├── dashboard-application.yaml
    └── dashboard/
        └── ...
```

### Root App Pattern

`root-app.yaml` создаёт ArgoCD Application, которое отслеживает директорию `gitops/apps/` и автоматически создаёт Application для каждого `*-application.yaml`.

### Добавление Нового Приложения

1. Создать директорию `gitops/apps/<app-name>/`
2. Добавить K8s-манифесты (deployment, service, etc.)
3. Создать `gitops/apps/<app-name>-application.yaml`
4. Commit и push — ArgoCD синхронизирует автоматически

---

## 5. k3d Конфигурация

### registries.yaml

```yaml
mirrors:
  "registry.localhost:5002":
    endpoint:
      - "http://registry.localhost:5002"
```

### Port Mappings

| Host Port | Container Port | Назначение |
|-----------|----------------|-----------|
| `8080` | `80` | Ingress Controller |
| `8081` | `30081` | Argo CD |
| `8088` | `30888` | Hello API |
| `8090` | `30902` | MLflow |
| `9090` | `30900` | MinIO API |
| `9091` | `30901` | MinIO Console |
| `32443` | `32443` | K8s Dashboard |
| `6550` | `6443` | K8s API |

---

## 🔧 Типичные Изменения

### Изменить порты

1. Отредактировать `.env`
2. `stop.bat --clean && start.bat`

### Изменить версии приложений

1. Отредактировать `GITEA_VERSION`, `WOODPECKER_VERSION`, etc. в `.env`
2. `stop.bat --clean && start.bat`

### Изменить credentials

> [!WARNING]
> После изменения credentials требуется **полная очистка**.

1. Отредактировать `.env`
2. `stop.bat --clean && start.bat`

---

## 🔗 Связанная Документация

- [ARCHITECTURE.md](ARCHITECTURE.md) — Архитектура системы
- [SCRIPTS.md](SCRIPTS.md) — Справочник скриптов
- [INSTALLATION.md](INSTALLATION.md) — Инструкции по установке
