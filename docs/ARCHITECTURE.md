# Архитектура GitOpsLab

Полное описание архитектуры платформы, взаимодействия компонентов и потока данных.

---

## 🏗️ Обзор Системы

GitOpsLab — это демонстрационная платформа "IDP-in-a-Box", объединяющая **GitOps** и **MLOps** практики в единую автоматизированную среду.

```mermaid
graph TB
    subgraph Host["🖥️ Windows Host"]
        Browser[Браузер]
        StartBat[start.bat]
    end

    subgraph Podman["🐋 Podman VM (WSL2)"]
        subgraph Compose["Docker Compose Services"]
            Gitea[(Gitea<br/>Git Server)]
            WPServer[Woodpecker<br/>Server]
            WPAgent[Woodpecker<br/>Agent]
            Bootstrap[Platform<br/>Bootstrap]
        end

        subgraph K3D["k3d Cluster (gitopslab)"]
            Registry[(Registry<br/>:5002)]
            ArgoCD[Argo CD]
            
            subgraph Apps["Namespace: apps"]
                HelloAPI[Hello API]
                MLflow[MLflow]
                MinIO[(MinIO)]
            end
            
            Dashboard[K8s Dashboard]
        end
    end

    StartBat --> Podman
    Browser --> Gitea
    Browser --> WPServer
    Browser --> ArgoCD
    Browser --> HelloAPI
    Browser --> MLflow
    Browser --> MinIO
    Browser --> Dashboard

    Gitea --> WPServer
    WPAgent --> WPServer
    WPAgent --> Registry
    Bootstrap --> K3D
    ArgoCD --> Gitea
    ArgoCD --> Apps
    MLflow --> MinIO
    HelloAPI --> MinIO
```

---

## 🧱 Компоненты Системы

### GitOps Layer (CI/CD)

| Компонент | Роль | Порт |
|-----------|------|------|
| **Gitea** | Git-сервер, хранит код и GitOps-манифесты | `3000` |
| **Woodpecker Server** | CI-сервер, управляет pipelines | `8000` |
| **Woodpecker Agent** | Выполняет jobs pipeline | — |
| **Argo CD** | GitOps-контроллер, синхронизирует K8s с Git | `8081` |
| **Registry (k3d)** | Container registry для образов | `5002` |

### MLOps Layer

| Компонент | Роль | Порт |
|-----------|------|------|
| **MLflow** | Tracking экспериментов и моделей | `8090` |
| **MinIO** | Object storage для артефактов ML | `9090/9091` |

### Platform Layer

| Компонент | Роль | Порт |
|-----------|------|------|
| **k3d** | Легковесный K3s кластер в контейнерах | `6550` (API) |
| **K8s Dashboard** | Веб-интерфейс управления кластером | `32443` |
| **Bootstrap** | Одноразовый контейнер инициализации | — |

---

## 🌐 Сетевая Топология

### Split-Horizon DNS

Система использует **split-horizon DNS** для разрешения имён:

```mermaid
graph LR
    subgraph Host["Host Browser"]
        H1[gitea.localhost:3000]
        H2[woodpecker.localhost:8000]
        H3[argocd.localhost:8081]
        H4[demo.localhost:8088]
    end

    subgraph Internal["Container Network"]
        I1[gitea:3000]
        I2[woodpecker-server:8000]
        I3[argocd-server.argocd.svc]
        I4[hello-api.apps.svc]
    end

    H1 -->|Port Forward| I1
    H2 -->|Port Forward| I2
    H3 -->|NodePort 30081| I3
    H4 -->|NodePort 30888| I4
```

### Маппинг Портов

| Host URL | Внутренний адрес | NodePort |
|----------|-----------------|----------|
| `gitea.localhost:3000` | `gitea:3000` | — |
| `woodpecker.localhost:8000` | `woodpecker-server:8000` | — |
| `argocd.localhost:8081` | `argocd-server:443` | `30081` |
| `demo.localhost:8088` | `hello-api:8080` | `30888` |
| `mlflow.localhost:8090` | `mlflow:5000` | `30902` |
| `minio.localhost:9090` | `minio:9000` | `30900` |
| `minio.localhost:9091` | `minio:9001` | `30901` |
| `dashboard.localhost:32443` | `dashboard:443` | `32443` |
| `registry.localhost:5002` | `k3d-registry:5000` | — |

### Сети

| Сеть | Назначение |
|------|-----------|
| `gitopslab` | Основная сеть для Podman-контейнеров |
| `k3d` | Сеть k3d кластера (внутренняя) |

---

## 🔄 Delivery Flow (CI/CD Pipeline)

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant Gitea as Gitea
    participant WP as Woodpecker
    participant Reg as Registry
    participant Argo as Argo CD
    participant K8s as K8s Cluster

    Dev->>Gitea: git push (code change)
    Gitea->>WP: Webhook trigger
    
    WP->>WP: 1. test (pytest)
    WP->>WP: 2. train-model (ML)
    WP->>WP: 3. upload-model (MinIO)
    WP->>Reg: 4. build & push image
    WP->>WP: 5. scan (Trivy)
    WP->>Gitea: 6. update-gitops (commit manifest)
    
    Note over Gitea,Argo: [skip ci] commit
    
    Argo->>Gitea: Poll for changes
    Argo->>K8s: Sync resources
    K8s->>Reg: Pull new image
```

### Этапы Pipeline

1. **test** — Запуск pytest для Hello API
2. **train-model** — Обучение ML-модели, логирование в MLflow
3. **upload-model** — Загрузка модели в MinIO
4. **build** — Сборка Docker-образа
5. **scan** — Сканирование уязвимостей (Trivy)
6. **update-gitops** — Обновление K8s-манифестов в Git

---

## 🤖 ML Flow (Model Training)

```mermaid
flowchart LR
    subgraph Pipeline["Woodpecker Pipeline"]
        Train[train.py]
        Upload[mc upload]
    end

    subgraph Storage["Object Storage"]
        MinIO[(MinIO<br/>ml-models/)]
    end

    subgraph Tracking["Experiment Tracking"]
        MLflow[MLflow<br/>Tracking Server]
    end

    subgraph App["Hello API"]
        ConfigMap[model-configmap.yaml]
        Pod[hello-api Pod]
    end

    Train -->|log metrics| MLflow
    Train -->|save model.joblib| Upload
    Upload --> MinIO
    Train -->|MODEL_SHA| ConfigMap
    ConfigMap --> Pod
    Pod -->|fetch model| MinIO
```

### Артефакты ML

| Артефакт | Хранилище | Путь |
|----------|-----------|------|
| `model.joblib` | MinIO | `ml-models/iris-{commit}.joblib` |
| `MODEL_OBJECT` | ConfigMap | `gitops/apps/hello/model-configmap.yaml` |
| `MODEL_SHA` | ConfigMap | SHA256 хеш модели |
| Метрики | MLflow | `hello-api-training` experiment |

---

## 📁 Структура GitOps Репозитория

```
gitops/
├── argocd/
│   └── root-app.yaml          # Root Application (App of Apps)
└── apps/
    ├── hello-application.yaml  # ArgoCD Application для Hello API
    ├── hello/
    │   ├── deployment.yaml     # 👈 Обновляется pipeline
    │   ├── service.yaml
    │   ├── ingress.yaml
    │   └── model-configmap.yaml # 👈 Обновляется pipeline
    ├── mlflow-application.yaml
    ├── mlflow/
    │   └── ...
    ├── minio-application.yaml
    ├── minio/
    │   └── ...
    ├── dashboard-application.yaml
    └── dashboard/
        └── ...
```

---

## 🔗 Связанная Документация

- [SCRIPTS.md](SCRIPTS.md) — Справочник всех скриптов
- [CONFIGURATION.md](CONFIGURATION.md) — Гид по конфигурации
- [INSTALLATION.md](INSTALLATION.md) — Инструкции по установке
- [LIFECYCLE.md](LIFECYCLE.md) — Управление жизненным циклом
- [HEALTH_CHECKS.md](HEALTH_CHECKS.md) — Система проверок здоровья
