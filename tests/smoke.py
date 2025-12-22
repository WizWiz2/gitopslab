"""
Простой смоук-тест платформы.
По умолчанию вызывает start.bat, если не передан --skip-start.
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
            if not line or line.startswith("#") or "=" not in line:
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
    raise RuntimeError(f"{name} not ready: {url}")


def wait_http_any(name: str, urls: Tuple[str, ...], allow_status: Tuple[int, ...] = (200,), attempts: int = 8, delay: float = 3.0):
    last_exc = None
    for u in dict.fromkeys(urls):
        try:
            wait_http(name, u, allow_status=allow_status, attempts=attempts, delay=delay)
            return
        except Exception as exc:  # noqa: BLE001
            last_exc = exc
            continue
    if last_exc:
        raise last_exc


def ensure_started(skip_start: bool):
    if skip_start:
        return
    start_script = os.path.join(REPO_ROOT, "start.bat")
    if not os.path.isfile(start_script):
        raise FileNotFoundError("start.bat not found")
    print("[start] running start.bat ...")
    subprocess.run(["cmd", "/c", start_script], cwd=REPO_ROOT, check=True)


def main():
    parser = argparse.ArgumentParser(description="Smoke-тест gitopslab")
    parser.add_argument("--skip-start", action="store_true", help="Не запускать start.bat перед проверкой")
    parser.add_argument("--timeout", type=int, default=240, help="Глобальный таймаут, сек")
    args = parser.parse_args()

    ensure_started(args.skip_start)

    env = read_env(ENV_PATH)
    gitea_port = env.get("GITEA_HTTP_PORT", "3000")
    gitea_ssh = env.get("GITEA_SSH_PORT", "2222")
    wood_port = env.get("WOODPECKER_SERVER_PORT", "8000")
    reg_port = env.get("REGISTRY_HTTP_PORT", "5001")
    argocd_port = env.get("ARGOCD_PORT", "8081")
    k3d_api = env.get("K3D_API_PORT", "6550")

    gitea_http = env.get("GITEA_PUBLIC_URL", f"http://localhost:{gitea_port}")
    wood_http = env.get("WOODPECKER_HOST", f"http://localhost:{wood_port}")
    argocd_http = env.get("ARGOCD_PUBLIC_URL", f"http://localhost:{argocd_port}")
    demo_http = env.get("DEMO_PUBLIC_URL", "http://demo.localhost:8088")

    gitea_candidates = (gitea_http, f"http://localhost:{gitea_port}")
    wood_candidates = (wood_http, f"http://localhost:{wood_port}")
    argocd_candidates = (argocd_http, f"http://localhost:{argocd_port}")
    demo_candidates = (demo_http, "http://localhost:8088")

    deadline = time.time() + args.timeout

    def wait_remaining():
        remaining = deadline - time.time()
        if remaining <= 0:
            raise TimeoutError("Global timeout exceeded")

    wait_remaining()
    wait_http_any("Gitea", tuple(f"{u}/api/v1/version" for u in gitea_candidates))

    wait_remaining()
    wait_http("Registry", f"http://localhost:{reg_port}/v2/", allow_status=(200,))

    wait_remaining()
    wait_http_any("Woodpecker", tuple(f"{u}/healthz" for u in wood_candidates), allow_status=(200, 204))

    wait_remaining()
    wait_http_any("Argo CD", argocd_candidates, allow_status=(200, 301, 302, 307, 401))

    wait_remaining()
    wait_http("K8s API", f"https://localhost:{k3d_api}/version", allow_status=(200, 401))

    wait_remaining()
    wait_http_any("Demo app", tuple(f"{u}/" for u in demo_candidates), allow_status=(200,))

    print("-------------------------------------------------------")
    print("All endpoints are reachable:")
    print(f"Gitea HTTP:  {gitea_candidates[0]}")
    print(f"Gitea SSH:   ssh://git@localhost:{gitea_ssh}")
    print(f"Woodpecker:  {wood_http}")
    print(f"Registry:    http://localhost:{reg_port}/v2/")
    print(f"Argo CD:     {argocd_http}")
    print(f"K8s API:     https://localhost:{k3d_api}")
    print(f"Demo app:    {demo_http}")
    print("-------------------------------------------------------")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001
        safe_msg = str(exc).encode("ascii", errors="ignore").decode()
        print(f"[FAIL] {safe_msg}")
        sys.exit(1)
