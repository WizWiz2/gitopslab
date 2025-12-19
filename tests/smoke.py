"""
Простейшие смоук-тесты для платформы.
Запускают start.bat (если не отключено) и проверяют, что основные сервисы отвечают.
Зависимости: стандартная библиотека Python 3 (requests не требуется).
Запуск:
  python tests/smoke.py              # запустит start.bat и проверит сервисы
  python tests/smoke.py --skip-start # если платформа уже поднята
"""

import argparse
import os
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from typing import Dict, Tuple


REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
ENV_PATH = os.path.join(REPO_ROOT, ".env")


def read_env(path: str) -> Dict[str, str]:
    env: Dict[str, str] = {}
    if not os.path.isfile(path):
        return env
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def http_check(url: str, timeout: float, allow_status: Tuple[int, ...]) -> int:
    ctx = ssl._create_unverified_context()
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        if e.code in allow_status:
            return e.code
        raise


def wait_http(name: str, url: str, allow_status: Tuple[int, ...] = (200,), attempts: int = 40, delay: float = 3.0):
    for i in range(1, attempts + 1):
        try:
            code = http_check(url, timeout=5.0, allow_status=allow_status)
            print(f"[ok] {name} -> {url} (status {code})")
            return
        except Exception as e:  # noqa: BLE001
            print(f"[wait] {name} ({url}) not ready ({e}); attempt {i}/{attempts}")
            time.sleep(delay)
    raise RuntimeError(f"{name} не ответил: {url}")


def ensure_started(skip_start: bool):
    if skip_start:
        return
    start_script = os.path.join(REPO_ROOT, "start.bat")
    if not os.path.isfile(start_script):
        raise FileNotFoundError("start.bat не найден")
    print("[start] Запускаю start.bat ...")
    # Используем cmd /c для корректного выполнения батника
    subprocess.run(["cmd", "/c", start_script], cwd=REPO_ROOT, check=True)


def main():
    parser = argparse.ArgumentParser(description="Смоук-тесты gitopslab")
    parser.add_argument("--skip-start", action="store_true", help="Не запускать start.bat перед проверками")
    parser.add_argument("--timeout", type=int, default=120, help="Максимальное время ожидания, сек")
    args = parser.parse_args()

    ensure_started(args.skip_start)

    env = read_env(ENV_PATH)
    gitea_port = env.get("GITEA_HTTP_PORT", "3000")
    gitea_ssh = env.get("GITEA_SSH_PORT", "2222")
    wood_port = env.get("WOODPECKER_SERVER_PORT", "8000")
    reg_port = env.get("REGISTRY_HTTP_PORT", "5001")
    argocd_port = env.get("ARGOCD_PORT", "8080")
    k3d_api = env.get("K3D_API_PORT", "6550")

    deadline = time.time() + args.timeout

    def wait_remaining():
        remaining = deadline - time.time()
        if remaining <= 0:
            raise TimeoutError("Время ожидания вышло")

    wait_remaining()
    wait_http("Gitea", f"http://localhost:{gitea_port}/api/v1/version")

    wait_remaining()
    wait_http("Registry", f"http://localhost:{reg_port}/v2/", allow_status=(200,))

    wait_remaining()
    wait_http("Woodpecker", f"http://localhost:{wood_port}/healthz", allow_status=(200, 204))

    wait_remaining()
    wait_http("Argo CD", f"http://localhost:{argocd_port}", allow_status=(200, 301, 302, 401))

    wait_remaining()
    wait_http("K8s API", f"https://localhost:{k3d_api}/version", allow_status=(200, 401))

    wait_remaining()
    wait_http("Demo app", "http://localhost:8088/", allow_status=(200,))

    print("-------------------------------------------------------")
    print("Все проверки прошли успешно")
    print(f"Gitea HTTP:  http://localhost:{gitea_port}")
    print(f"Gitea SSH:   ssh://git@localhost:{gitea_ssh}")
    print(f"Woodpecker:  http://localhost:{wood_port}")
    print(f"Registry:    http://localhost:{reg_port}/v2/")
    print(f"Argo CD:     http://localhost:{argocd_port}")
    print(f"K8s API:     https://localhost:{k3d_api}")
    print("Demo app:    http://localhost:8088")
    print("-------------------------------------------------------")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001
        print(f"[FAIL] {exc}")
        sys.exit(1)
