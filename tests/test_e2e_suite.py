import os
import sys
import subprocess
import pytest
import time
import urllib.request
import urllib.error
import ssl
from typing import Tuple

# Helper functions adapted from smoke.py
def http_check(url: str, timeout: float = 5.0, allow_status: Tuple[int, ...] = (200,)) -> int:
    ctx = ssl._create_unverified_context()
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        if e.code in allow_status:
            return e.code
        raise

def wait_http(name: str, url: str, allow_status: Tuple[int, ...] = (200,), attempts: int = 40, delay: float = 3.0):
    last_exc = None
    for i in range(1, attempts + 1):
        try:
            http_check(url, timeout=5.0, allow_status=allow_status)
            return
        except Exception as e:
            last_exc = e
            time.sleep(delay)
    raise RuntimeError(f"{name} not ready at {url}: {last_exc}")

def wait_http_any(name: str, urls: Tuple[str, ...], allow_status: Tuple[int, ...] = (200,), attempts: int = 10, delay: float = 3.0):
    last_exc = None
    for u in dict.fromkeys(urls):
        try:
            wait_http(name, u, allow_status=allow_status, attempts=attempts, delay=delay)
            return
        except Exception as exc:
            last_exc = exc
            continue
    if last_exc:
        raise last_exc

# Test Classes
class TestServiceHealth:
    def test_gitea_reachable(self):
        port = os.environ.get("GITEA_HTTP_PORT", "3000")
        url = os.environ.get("GITEA_PUBLIC_URL", f"http://localhost:{port}")
        wait_http_any("Gitea", (f"{url}/api/v1/version", f"http://localhost:{port}/api/v1/version"))

    def test_registry_reachable(self):
        port = os.environ.get("REGISTRY_HTTP_PORT", "5001")
        url = f"http://localhost:{port}/v2/"
        wait_http("Registry", url)

    def test_woodpecker_reachable(self):
        port = os.environ.get("WOODPECKER_SERVER_PORT", "8000")
        url = os.environ.get("WOODPECKER_HOST", f"http://localhost:{port}")
        wait_http_any("Woodpecker", (f"{url}/healthz", f"http://localhost:{port}/healthz"), allow_status=(200, 204))

    def test_argocd_reachable(self):
        port = os.environ.get("ARGOCD_PORT", "8081")
        url = os.environ.get("ARGOCD_PUBLIC_URL", f"http://localhost:{port}")
        try:
            wait_http_any("Argo CD", (url, f"http://localhost:{port}"), allow_status=(200, 301, 302, 307, 401))
        except RuntimeError:
            pytest.fail("Argo CD is not reachable.")

    def test_k8s_api_reachable(self):
        port = os.environ.get("K3D_API_PORT", "6550")
        url = f"https://localhost:{port}/version"
        wait_http("K8s API", url, allow_status=(200, 401))

    def test_minio_reachable(self):
        if os.environ.get("SKIP_MINIO"):
            pytest.skip("Skipping MinIO checks")
        port = os.environ.get("MINIO_API_PORT", "9090")
        url = os.environ.get("MINIO_PUBLIC_URL", f"http://minio.localhost:{port}")
        wait_http_any("MinIO", (f"{url}/minio/health/ready", f"http://localhost:{port}/minio/health/ready"))

    def test_mlflow_reachable(self):
        if os.environ.get("SKIP_MLFLOW"):
            pytest.skip("Skipping MLflow checks")
        port = os.environ.get("MLFLOW_PORT", "8090")
        url = os.environ.get("MLFLOW_PUBLIC_URL", f"http://mlflow.localhost:{port}")
        wait_http_any("MLflow", (f"{url}/", f"http://localhost:{port}/"))

    def test_demo_app_reachable(self):
        url = os.environ.get("DEMO_PUBLIC_URL", "http://demo.localhost:8088")
        wait_http_any("Demo app", (f"{url}/", "http://localhost:8088/"))


class TestE2EScenario:
    def test_run_e2e_script(self):
        """
        Runs the E2E scenario.
        Attempts to run 'run-e2e.bat' on Windows, or the python implementation 'tests/e2e_impl.py' otherwise.
        """
        repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
        bat_path = os.path.join(repo_root, "run-e2e.bat")
        py_impl_path = os.path.join(repo_root, "tests", "e2e_impl.py")

        if os.name == 'nt' and os.path.exists(bat_path):
            print(f"Running {bat_path}...")
            # .bat files on Windows need shell=True or explicit cmd /c
            # passing timeout 600
            result = subprocess.run([bat_path, "600"], shell=True, capture_output=True, text=True)
            print("STDOUT:", result.stdout)
            print("STDERR:", result.stderr)

            if result.returncode != 0:
                pytest.fail(f"E2E script failed with exit code {result.returncode}. See stdout/stderr for details.")
        else:
            if not os.path.exists(py_impl_path):
                 pytest.fail(f"e2e python implementation not found at {py_impl_path}")

            print(f"Running {py_impl_path}...")
            # Run the python script
            cmd = [sys.executable, py_impl_path]
            # Stream output live would be better, but capture_output=True is easier for now to check result
            result = subprocess.run(cmd, capture_output=True, text=True)

            print("STDOUT:", result.stdout)
            print("STDERR:", result.stderr)

            if result.returncode != 0:
                pytest.fail(f"E2E python script failed with exit code {result.returncode}. See stdout/stderr for details.")

@pytest.fixture(scope="function", autouse=True)
def diagnose_argocd_failure(request):
    """
    If Argo CD test failed, attempt to fetch logs from the container.
    """
    yield
    # Check if the test failed. rep_call is set by a hook if present, but here we can try a simpler way
    # or just run diagnostics if it's the right test.
    if request.node.name == "test_argocd_reachable":
        print("\n[DIAGNOSTIC] Argo CD check failed. Attempting to fetch logs...")

        # Try docker compose first if available
        compose_cmd = None
        try:
             subprocess.run(["docker", "compose", "version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
             compose_cmd = ["docker", "compose"]
        except FileNotFoundError:
             try:
                 subprocess.run(["podman-compose", "--version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                 compose_cmd = ["podman-compose"]
             except FileNotFoundError:
                 pass

        if compose_cmd:
            print(f"[DIAGNOSTIC] Running {' '.join(compose_cmd)} logs argocd --tail 50")
            try:
                subprocess.run(compose_cmd + ["logs", "argocd", "--tail", "50"], check=False)
            except Exception as e:
                print(f"[DIAGNOSTIC] Failed to fetch logs: {e}")
        else:
            # Fallback to podman/docker logs directly if we can guess the name
            print("[DIAGNOSTIC] docker-compose/podman-compose not found. Trying 'podman logs -l' (latest container)...")
            try:
                subprocess.run(["podman", "logs", "-l", "--tail", "50"], check=False)
            except FileNotFoundError:
                 print("[DIAGNOSTIC] podman not found.")
