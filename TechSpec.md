Ниже — полная версия ТЗ (DOC_1_TZ.md) с учётом всех правок/рисков, в одном цельном документе. Можешь копипастить как есть.

⸻

DOC_1_TZ.md — One-Click DevOps Demo Platform (IDP-in-a-Box)

1) Цель проекта

Создать демонстрационную платформу “в один клик” (одна команда), которая показывает навыки DevOps/Platform Engineering:
	•	локальная воспроизводимая платформа без облака
	•	инфраструктура и приложения управляются декларативно (IaC/GitOps принципы)
	•	CI/CD pipeline: test → build → security scan → push image → update gitops → deploy
	•	наличие UI/наблюдаемости для демонстрации “как у взрослых”
	•	проект удобен для портфолио: docs, диаграммы, runbooks, демо-сценарии

Ключевое требование запуска:

docker compose up -d

После выполнения команды платформа должна автоматически bootstrap’иться до полностью рабочего состояния без ручных действий.

⸻

2) Нефункциональные требования

2.1 Платформенность
	•	Репозиторий “platform-in-a-repo” (mono-repo по умолчанию).
	•	GitOps обязателен: Argo CD управляет состоянием кластера.
	•	Запрещены ручные kubectl apply как основной способ доставки (только для диагностики/отладки).

2.2 Повторяемость и идемпотентность
	•	Повторный запуск bootstrap не должен ломать систему.
	•	up и down возвращают систему в известное состояние.
	•	Обязателен сценарий полного “wipe/reset” для чистого старта.

2.3 Демонстрационность
	•	Должны быть UI:
	•	Git (Gitea)
	•	CI (Woodpecker)
	•	GitOps/CD (Argo CD)
	•	Должен быть сценарий демо на 5–7 минут (docs/DEMO.md), включающий:
	•	изменение в коде
	•	прохождение CI
	•	автоматический деплой через Argo CD
	•	проверка /version
	•	(опц.) rollback и self-heal демонстрация

2.4 Простота
	•	Платформа работает локально на ноутбуке.
	•	Минимальные зависимости: Docker + Docker Compose (желательно без обязательного kubectl на хосте).

2.5 Ресурсные ограничения
	•	Docker Compose должен задавать лимиты ресурсов для сервисов, чтобы стенд не “вешал” ноутбук.
	•	Значения лимитов должны быть описаны в документации и легко настраиваться через .env.

⸻

3) Выбранный стек (по умолчанию)

3.1 Оркестрация и инфраструктура (локально)
	•	Docker Compose — точка входа (one command)
	•	k3d (k3s-in-docker) — локальный Kubernetes внутри Docker
	•	Bootstrap контейнер — автоматизация: k3d + Argo CD + init Gitea/Woodpecker + app-of-apps

3.2 SCM (Git)
	•	Gitea — локальный git-server с UI и API

3.3 CI
	•	Woodpecker CI — server + agent (runner)

3.4 Registry
	•	Docker Registry v2 — локальный registry

3.5 GitOps/CD
	•	Argo CD — деплой в кластер из Git репозитория, подход “App of Apps”

3.6 Security/Quality
	•	Trivy — сканирование образов (fail on High/Critical)
	•	kubeconform или kube-linter — проверка манифестов (желательно)
	•	(опционально) Kyverno — политики (например запрет :latest)

3.7 Demo App
	•	hello-api (FastAPI/Go/Node) — сервис с /healthz и /version

⸻

4) Архитектура (логическая)

4.1 Компоненты

Docker Compose слой:
	•	gitea — Git UI + API
	•	registry — Docker registry
	•	woodpecker-server — CI UI + API
	•	woodpecker-agent — runner
	•	bootstrap — сценарий авто-развёртывания (k3d + Argo + init)

Kubernetes слой (k3d cluster):
	•	argocd namespace — Argo CD
	•	apps namespace — demo приложения
	•	platform namespace — платформенные компоненты (при необходимости)
	•	(опционально) observability namespace

4.2 Основной поток доставки (Delivery flow)
	1.	Разработчик меняет код demo приложения в Gitea.
	2.	CI (Woodpecker) запускает pipeline:
	•	unit tests
	•	build Docker image
	•	Trivy scan (gate)
	•	push image в локальный registry
	•	обновление GitOps манифеста (image tag) + commit/push
	3.	Argo CD видит изменение в GitOps каталоге → синхронизирует кластер → деплой.
	4.	Проверка результата через /version.

⸻

5) Модель репозитория (mono-repo по умолчанию)

Один репозиторий platform в Gitea, содержащий:

platform/
  docker-compose.yml
  .env.example
  .gitignore
  .dockerignore
  scripts/
    bootstrap.sh
    wait-for.sh
    init-gitea.sh
    init-woodpecker.sh
    init-argocd.sh
    registries.yaml
  apps/
    hello-api/
      Dockerfile
      src/...
      tests/...
  gitops/
    argocd/
      root-app.yaml
      projects.yaml         # (опц) Argo Projects/RBAC
    apps/
      hello/
        Chart.yaml
        values.yaml
        templates/
          deployment.yaml
          service.yaml
          ingress.yaml
  ci/
    .woodpecker.yml
  docs/
    DEMO.md
    ARCHITECTURE.md
    RUNBOOKS.md


⸻

6) Интерфейсы и порты (с хоста)
	•	Gitea: http://gitea.localhost:3000
	•	Woodpecker: http://woodpecker.localhost:8000
	•	Argo CD: http://argocd.localhost:8081 (должно открываться с хоста)
	•	Demo App: http://localhost:8088 (или чёткая инструкция, как получить доступ)

Требование: bootstrap в конце печатает URLs + креды + команды быстрой проверки.

⸻

6.5 Networking & DNS (Known Pain Points)

В проекте есть три “сети”:
	1.	Host network (браузер на ноутбуке): обращается к localhost:<port>
	2.	Docker Compose network (контейнеры): общаются по DNS имени сервиса (gitea, registry, …)
	3.	k3d network/Kubernetes: ArgoCD и pods должны уметь достучаться до Git и registry

6.5.1 Split-horizon правила (обязательные)

Нужно разделять адреса для пользователя и для внутренней автоматизации:

Public URL (для человека на хосте) vs Internal URL (для контейнеров/кластера).

В .env.example должны быть переменные:
	•	GITEA_PUBLIC_URL=http://localhost:3000
	•	GITEA_INTERNAL_URL=http://gitea:3000
	•	REGISTRY_PUBLIC=localhost:5000
	•	REGISTRY_INTERNAL=registry:5000

Правило:
	•	В UI/доках/выводе bootstrap использовать *_PUBLIC_*
	•	В bootstrap/CI/Argo использовать *_INTERNAL_*

Также рекомендуется:
	•	В docker-compose задать hostname: gitea и/или network alias, чтобы внутренний DNS был стабильным.

6.5.2 Clone URL problem (“localhost trap”)

Если Gitea ROOT_URL = localhost, контейнеры не смогут клонировать репо по localhost.

Требование: CI clone должен всегда идти по GITEA_INTERNAL_URL.

Допустимые реализации (выбрать минимум одну и зафиксировать):
	•	A) Переопределить clone URL в настройках Woodpecker/SCM (если доступно)
	•	B) В pipeline сделать rewrite:
	•	git config --global url."${GITEA_INTERNAL_URL}/".insteadOf "${GITEA_PUBLIC_URL}/"
	•	C) Использовать единый адрес host.docker.internal (если гарантированно работает на целевой ОС; иначе не использовать)

6.5.3 ArgoCD доступ к Git

ArgoCD репозиторий регистрирует по internal URL (GITEA_INTERNAL_URL) + PAT.

⸻

6.6 Insecure Registry (HTTP)

Локальный registry работает по HTTP. Kubernetes (containerd) и CI могут ругаться на отсутствие TLS.

Требование:
	•	Для k3d обязателен registries.yaml с конфигом, разрешающим HTTP endpoint.
	•	Pipeline должен пушить без TLS-ошибок.

Рекомендованный паттерн:
	•	CI push идёт в REGISTRY_PUBLIC (localhost:5000/...), чтобы пуш выполнялся через docker daemon, который уже знает доступ к localhost.
	•	Kubernetes pull обеспечивается через k3d registries.yaml, который указывает endpoint http://registry:5000.

⸻

6.7 GitOps infinite loop prevention

Сценарий: CI делает commit (bump tag) → триггерит CI снова → бесконечная петля.

Требование:
	•	Коммит, который делает CI, обязан содержать маркер "[skip ci]" или Woodpecker должен игнорировать коммиты от CI-бота.

⸻

6.8 Woodpecker Trusted Mode

Чтобы pipeline мог использовать docker.sock и privileged шаги, репозиторий должен быть trusted.

Требование:
	•	При bootstrap включить репозиторий и выставить trusted: true (через API/конфиг).

⸻

6.9 Reset / Wipe сценарий

Нужен гарантированный способ стереть всё и начать заново.

Требование:
	•	Описать и поддерживать сценарий полного сброса: docker compose down -v
	•	Stateful данные должны храниться в named volumes по умолчанию.
	•	Если используются bind mounts — должен существовать скрипт очистки (например scripts/wipe.sh), который удаляет данные безопасно.

⸻

7) Bootstrap процесс (обязательный, полностью автоматический)

Bootstrap выполняется контейнером bootstrap и не требует ручных действий.

7.1 Шаги bootstrap
	1.	Ожидание готовности Gitea/Registry/Woodpecker (healthchecks).
	2.	Создание k3d cluster idp-demo (идемпотентно).
	3.	Подключение registry к кластеру:
	•	создание/использование scripts/registries.yaml (HTTP endpoint)
	4.	Установка Argo CD в кластер, ожидание ready.
	5.	Инициализация Gitea:
	•	создать пользователя (например demo)
	•	создать репозиторий platform
	•	seed repo content (если пусто)
	•	создать PAT (для CI/Argo)
	6.	Инициализация Woodpecker:
	•	включить репозиторий platform
	•	установить trusted: true
	•	добавить секреты (PAT, registry endpoints)
	7.	Настройка Argo CD:
	•	добавить репозиторий (source) по GITEA_INTERNAL_URL + PAT
	•	применить gitops/argocd/root-app.yaml
	8.	Финальный вывод:
	•	URLs (public)
	•	креды (masked/аккуратно)
	•	“как сделать демо коммит”
	•	диагностика

7.2 Идемпотентность
	•	Каждый шаг должен проверять существование ресурса и выполнять create только при необходимости.
	•	Ошибки должны быть понятны и вести в RUNBOOKS.

⸻

8) CI pipeline (обязательный минимум)

Pipeline стадии:
	1.	Test — unit tests
	2.	Build — образ: REGISTRY_PUBLIC/hello-api:${COMMIT_SHA} (пример: localhost:5000/hello-api:<sha>)
	3.	Scan — Trivy scan (fail on High/Critical)
	4.	Push — push в registry
	5.	Lint manifests (желательно) — kubeconform/kube-linter для gitops/
	6.	Update GitOps — bump image tag в gitops/apps/hello/values.yaml, commit message содержит "[skip ci]", push
	7.	Deploy — Argo CD автоматически применяет изменения

Требование: CI clone репозитория должен использовать GITEA_INTERNAL_URL (см. 6.5.2).

⸻

9) GitOps (Argo CD)

9.1 Root App (App-of-Apps)

gitops/argocd/root-app.yaml должен:
	•	указывать на repo platform
	•	использовать path gitops/apps
	•	включать automated sync:
	•	prune: true
	•	selfHeal: true

9.2 Demo self-heal

Должен быть описан сценарий, как вручную “внести drift” (например изменить replicas) и показать, что Argo вернул состояние.

⸻

10) Demo App требования

10.1 Hello API
	•	/ → “Hello from IDP demo”
	•	/healthz → ok
	•	/version → текущая версия (commit/tag), чтобы демонстрировать выкаты

10.2 Kubernetes manifests
	•	Deployment:
	•	requests/limits
	•	readiness/liveness probes
	•	минимум 1 реплика
	•	Service
	•	Ingress (если используется публичный доступ) или документированный port-forward

⸻

11) Security и Quality gates

Минимальный обязательный набор:
	•	Trivy scan image с политикой fail on High/Critical
	•	(желательно) kubeconform/kube-linter для манифестов

Опционально:
	•	Kyverno policy pack (например запрет :latest)

⸻

12) Документация (обязательная)

docs/DEMO.md
	•	запуск
	•	URLs + логины/пароли
	•	сценарий демо 5–7 минут:
	1.	показать ArgoCD (Healthy)
	2.	сделать commit в hello-api
	3.	показать CI pipeline
	4.	показать Argo sync
	5.	открыть /version
	6.	(опц.) rollback
	7.	(опц.) self-heal (drift → reconcile)

docs/ARCHITECTURE.md
	•	компонентная диаграмма (mermaid)
	•	обязательно: network map (split-horizon):
	•	Host Browser → localhost:3000 → Gitea container
	•	Woodpecker Agent → gitea:3000 (internal)
	•	ArgoCD → gitea:3000 (internal)
	•	CI push → localhost:5000 (public)
	•	k8s pull → registry:5000 (internal via registries.yaml)

docs/RUNBOOKS.md
	•	диагностика:
	•	k3d не поднялся
	•	ArgoCD недоступен
	•	registry SSL/HTTP issues
	•	CI clone URL issues
	•	CI loop
	•	команды:
	•	docker compose logs -f <svc>
	•	kubectl get pods -A (через bootstrap)
	•	k3d cluster list

⸻

13) Acceptance Criteria (готовность проекта)
	1.	docker compose up -d → платформа готова без ручных шагов.
	2.	Открываются UI:
	•	http://gitea.localhost:3000 (Gitea)
	•	http://woodpecker.localhost:8000 (Woodpecker)
	•	http://argocd.localhost:8081 (Argo CD)
	3.	Demo app доступен с хоста и /version показывает текущую версию.
	4.	Изменение кода → CI (test/build/scan/push) → bump gitops (skip ci) → Argo deploy.
	5.	Есть DEMO.md, ARCHITECTURE.md (включая network map), RUNBOOKS.md.
	6.	Повторный запуск bootstrap не ломает окружение (идемпотентность).
	7.	Есть wipe/reset сценарий и он работает (docker compose down -v).

⸻


