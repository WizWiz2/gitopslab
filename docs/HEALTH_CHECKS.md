# GitOps Lab - Health Check & Monitoring System

Система самодиагностики и мониторинга для раннего обнаружения проблем в инфраструктуре.

## 📋 Компоненты

### 1. **Pre-flight Checks** (`scripts/preflight-check.bat`)
Проверки **перед запуском** платформы:
- ✅ Наличие `.env` файла
- ✅ Доступность Podman
- ✅ Статус Podman machine
- ✅ Корректность IP-адресов в конфигурации
- ✅ Наличие Python 3.11/3.12
- ✅ Свободное место на диске

**Использование:**
```batch
scripts\preflight-check.bat
```

**Интеграция:** Автоматически запускается в `start.bat`

---

### 2. **Smoke Tests** (`tests/smoke.py`)
Быстрая проверка **работающей** платформы (30-60 секунд):
- ✅ Сетевой шлюз k3d
- ✅ Docker API доступность
- ✅ Container Registry
- ✅ Gitea сервис
- ✅ Woodpecker сервис
- ✅ OAuth конфигурация
- ✅ k3d кластер
- ✅ ArgoCD deployment

**Использование:**
```batch
# Standalone
python tests\smoke.py

# С pytest
pytest tests\smoke.py -v

# Только критичные проверки
pytest tests\smoke.py -k "network or registry or gitea"
```

---

### 3. **Full Health Check** (`scripts/health-check.sh`)
Комплексная проверка всех компонентов (2-3 минуты):
- ✅ Все проверки из Smoke Tests
- ✅ Межсервисная связность
- ✅ Woodpecker database состояние
- ✅ Консистентность конфигурационных файлов
- ✅ ArgoCD pods статус

**Использование:**
```batch
# Через Docker/Podman
podman run --rm --network k3d ^
    -v "%CD%:/workspace" ^
    -v /run/podman/podman.sock:/var/run/docker.sock ^
    --env-file .env ^
    gitopslab_bootstrap /workspace/scripts/health-check.sh

# Или через wrapper
health-check.bat full
```

---

### 4. **Unified Health Check Runner** (`health-check.bat`)
Единая точка входа для всех проверок:

```batch
# Все проверки
health-check.bat all

# Только pre-flight
health-check.bat preflight

# Только smoke tests
health-check.bat smoke

# Только full check
health-check.bat full
```

---

## 🚀 Рекомендуемый Workflow

### При первом запуске:
```batch
1. health-check.bat preflight    # Проверка окружения
2. start.bat                      # Запуск платформы
3. health-check.bat smoke         # Быстрая проверка
4. run-e2e.bat                    # Полный E2E тест
```

### Ежедневная проверка:
```batch
health-check.bat smoke
```

### При подозрении на проблемы:
```batch
health-check.bat full
```

### В CI/CD pipeline:
```yaml
# .woodpecker.yml
steps:
  validate-platform:
    image: python:3.10-slim
    commands:
      - pip install pytest requests
      - pytest tests/smoke.py -v
```

---

## 🔍 Типичные Проблемы и Диагностика

### ❌ "Gateway IP mismatch"
**Причина:** IP в `.env` не совпадает с реальным шлюзом k3d сети

**Решение:**
```batch
# Узнать реальный IP
podman network inspect k3d --format "{{range .IPAM.Config}}{{.Gateway}}{{end}}"

# Обновить .env
# HOST_GATEWAY_IP=<полученный_IP>
```

---

### ❌ "Docker API not accessible"
**Причина:** Podman API service не запущен на правильном IP

**Решение:**
```batch
# Перезапустить Podman machine
podman machine stop
podman machine start

# Проверить API
curl http://10.89.0.1:2375/version
```

---

### ❌ "Registry not accessible"
**Причина:** k3d-registry контейнер не запущен или недоступен

**Решение:**
```batch
# Проверить контейнер
podman ps | findstr k3d-registry

# Пересоздать если нужно
podman rm -f k3d-registry.localhost
start.bat
```

---

### ❌ "OAuth configuration incomplete"
**Причина:** `WOODPECKER_GITEA_CLIENT` или `SECRET` не настроены

**Решение:**
1. Войти в Woodpecker: http://woodpecker.localhost:8000
2. Авторизоваться через Gitea
3. Перезапустить `start.bat` для автоматической настройки

---

### ❌ "Woodpecker user not found in database"
**Причина:** Пользователь не выполнил первый вход в Woodpecker

**Решение:**
1. Открыть http://woodpecker.localhost:8000
2. Нажать "Login" → авторизоваться через Gitea
3. Активировать репозиторий `gitops/platform`

---

## 📊 Интеграция с Мониторингом

### Prometheus Metrics (будущее расширение)
```python
# В smoke.py можно добавить:
from prometheus_client import Gauge, push_to_gateway

health_status = Gauge('gitopslab_health_status', 
                      'Platform health check status',
                      ['component'])

# После каждой проверки
health_status.labels(component='registry').set(1 if passed else 0)
```

### Slack Notifications
```batch
REM В health-check.bat
if errorlevel 1 (
    curl -X POST -H "Content-Type: application/json" ^
         -d "{\"text\":\"GitOps Lab health check FAILED\"}" ^
         %SLACK_WEBHOOK_URL%
)
```

---

## 🛠️ Расширение Системы

### Добавление новой проверки в smoke.py:
```python
def check_my_service(self) -> bool:
    """Verify my custom service"""
    try:
        response = requests.get("http://my-service:8080/health")
        return response.status_code == 200
    except Exception as e:
        self.errors.append(f"My service check failed: {e}")
        return False

# В run_all_checks():
results["my_service"] = self.check_my_service()
```

### Добавление проверки в health-check.sh:
```bash
check_my_service() {
    log "Checking my custom service..."
    
    if ! curl -s --max-time 3 "http://my-service:8080/health" >/dev/null 2>&1; then
        error "My service not accessible"
        ((ERRORS++))
    else
        log "✓ My service accessible"
    fi
}

# В main():
check_my_service
```

---

## 📈 Метрики и Статистика

Система собирает следующие метрики:
- **Время выполнения** каждой проверки
- **Количество ошибок** и предупреждений
- **Историю** изменений статуса (если логируется)

### Пример логирования:
```batch
health-check.bat all >> logs\health-check-%DATE%.log 2>&1
```

---

## 🎯 Best Practices

1. **Запускайте pre-flight** перед каждым `start.bat`
2. **Smoke tests** после изменений в конфигурации
3. **Full health check** раз в день или при деплое
4. **E2E tests** перед коммитом критичных изменений
5. **Логируйте результаты** для анализа трендов

---

## 📝 Changelog

### v1.0.0 (2026-01-04)
- ✨ Добавлена система pre-flight checks
- ✨ Созданы smoke tests с pytest
- ✨ Реализован full health check
- ✨ Unified health check runner
- 🔧 Интеграция с start.bat
