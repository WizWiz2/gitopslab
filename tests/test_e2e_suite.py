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
    """
    Check an HTTP(S) URL and return its response status code.
    
    Parameters:
        url (str): The full URL to request.
        timeout (float): Request timeout in seconds.
        allow_status (Tuple[int, ...]): HTTP status codes that should be treated as acceptable
            even if raised as an HTTPError; such codes are returned.
    
    Returns:
        int: The HTTP response status code.
    
    Notes:
        SSL certificate verification is disabled for the request.
        HTTP errors with codes not in `allow_status` are propagated.
    """
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
    """
    Waits until the given URL responds with one of the allowed HTTP statuses or raises if it does not become ready in time.
    
    Parameters:
        name (str): Human-readable name of the service used in the error message.
        url (str): The HTTP(S) URL to poll.
        allow_status (Tuple[int, ...]): HTTP status codes treated as successful responses (default: (200,)).
        attempts (int): Maximum number of polling attempts before giving up (default: 40).
        delay (float): Seconds to wait between attempts (default: 3.0).
    
    Raises:
        RuntimeError: If the URL does not return an allowed status within the specified attempts; the exception message includes the last encountered error.
    """
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
    """
    Waits until any of the given URLs responds with an allowed HTTP status.
    
    Checks each unique URL in order and returns as soon as one URL is reachable with a status in `allow_status`. If none of the URLs become ready, re-raises the last encountered exception.
    
    Parameters:
        name (str): Human-readable name of the service used in diagnostics or error messages.
        urls (Tuple[str, ...]): Sequence of URL strings to try; duplicate URLs are ignored.
        allow_status (Tuple[int, ...], optional): HTTP status codes considered successful (default: (200,)).
        attempts (int, optional): Number of polling attempts to perform per URL (default: 10).
        delay (float, optional): Seconds to wait between attempts (default: 3.0).
    
    Raises:
        Exception: The last exception raised while checking the URLs if none become ready.
    """
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
        """
        Verify that the Gitea service becomes reachable by polling its version endpoint.
        
        Polls the /api/v1/version endpoint on either the public URL taken from the GITEA_PUBLIC_URL environment variable
        (or http://localhost:{GITEA_HTTP_PORT} if unset) or directly on localhost using GITEA_HTTP_PORT (default 3000)
        until an allowed HTTP status is observed or the retry limit is reached.
        """
        port = os.environ.get("GITEA_HTTP_PORT", "3000")
        url = os.environ.get("GITEA_PUBLIC_URL", f"http://localhost:{port}")
        wait_http_any("Gitea", (f"{url}/api/v1/version", f"http://localhost:{port}/api/v1/version"))

    def test_registry_reachable(self):
        """
        Verify the local container registry's v2 API is reachable.
        
        Reads the REGISTRY_HTTP_PORT environment variable (default "5001"), constructs http://localhost:{port}/v2/, and waits until that endpoint returns an allowed HTTP status.
        """
        port = os.environ.get("REGISTRY_HTTP_PORT", "5001")
        url = f"http://localhost:{port}/v2/"
        wait_http("Registry", url)

    def test_woodpecker_reachable(self):
        """
        Check that the Woodpecker server becomes reachable via its health endpoint.
        
        Reads WOODPECKER_SERVER_PORT and WOODPECKER_HOST environment variables (with defaults), constructs candidate health-check URLs, and waits until one returns HTTP status 200 or 204.
        """
        port = os.environ.get("WOODPECKER_SERVER_PORT", "8000")
        url = os.environ.get("WOODPECKER_HOST", f"http://localhost:{port}")
        wait_http_any("Woodpecker", (f"{url}/healthz", f"http://localhost:{port}/healthz"), allow_status=(200, 204))

    def test_argocd_reachable(self):
        """
        Check that Argo CD's HTTP endpoint is reachable; fail the test if no allowed response is received.
        
        Determines target URLs from the ARGOCD_PORT and ARGOCD_PUBLIC_URL environment variables and considers HTTP statuses 200, 301, 302, 307, or 401 as successful.
        """
        port = os.environ.get("ARGOCD_PORT", "8081")
        url = os.environ.get("ARGOCD_PUBLIC_URL", f"http://localhost:{port}")
        try:
            wait_http_any("Argo CD", (url, f"http://localhost:{port}"), allow_status=(200, 301, 302, 307, 401))
        except RuntimeError:
            pytest.fail("Argo CD is not reachable.")

    def test_k8s_api_reachable(self):
        """
        Waits until the local Kubernetes API endpoint becomes reachable and reports a successful HTTP status.
        
        Polls the API endpoint at https://localhost:{K3D_API_PORT}/version (default port 6550) and completes when the service responds with HTTP 200 or 401; fails the test if the endpoint does not become ready within the configured attempts.
        """
        port = os.environ.get("K3D_API_PORT", "6550")
        url = f"https://localhost:{port}/version"
        wait_http("K8s API", url, allow_status=(200, 401))

    def test_minio_reachable(self):
        """
        Check that a MinIO service becomes ready by polling its readiness endpoints.
        
        Skips the test if the environment variable `SKIP_MINIO` is set. Uses
        `MINIO_API_PORT` (default "9090") and `MINIO_PUBLIC_URL` (default "http://minio.localhost:{port}")
        to form two readiness URLs and waits until one of them returns an allowed HTTP status.
        """
        if os.environ.get("SKIP_MINIO"):
            pytest.skip("Skipping MinIO checks")
        port = os.environ.get("MINIO_API_PORT", "9090")
        url = os.environ.get("MINIO_PUBLIC_URL", f"http://minio.localhost:{port}")
        wait_http_any("MinIO", (f"{url}/minio/health/ready", f"http://localhost:{port}/minio/health/ready"))

    def test_mlflow_reachable(self):
        """
        Waits for the MLflow service to become reachable by polling its experiments list endpoints.
        
        If the SKIP_MLFLOW environment variable is set, the test is skipped. The function constructs a public URL from MLFLOW_PUBLIC_URL or a localhost URL using MLFLOW_PORT and polls those endpoints until one returns an allowed HTTP status; the test fails if none become ready within the configured attempts.
        """
        if os.environ.get("SKIP_MLFLOW"):
            pytest.skip("Skipping MLflow checks")
        port = os.environ.get("MLFLOW_PORT", "8090")
        url = os.environ.get("MLFLOW_PUBLIC_URL", f"http://mlflow.localhost:{port}")
        wait_http_any("MLflow", (f"{url}/api/2.0/mlflow/experiments/list", f"http://localhost:{port}/api/2.0/mlflow/experiments/list"))

    def test_demo_app_reachable(self):
        """
        Waits for the Demo application's root HTTP endpoint to become reachable.
        
        Reads the DEMO_PUBLIC_URL environment variable (default "http://demo.localhost:8088") and polls the root path of either that URL or "http://localhost:8088/" until one responds with an allowed status or the polling attempts are exhausted.
        """
        url = os.environ.get("DEMO_PUBLIC_URL", "http://demo.localhost:8088")
        wait_http_any("Demo app", (f"{url}/", "http://localhost:8088/"))


class TestE2EScenario:
    def test_run_e2e_script(self):
        """
        Execute the repository's end-to-end scenario.
        
        If running on Windows and run-e2e.bat exists, executes that batch file (passing a timeout argument); otherwise runs tests/e2e_impl.py with the current Python interpreter. Prints captured stdout/stderr and fails the test if the chosen script is missing or exits with a non-zero status.
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
    if request.node.name == "test_argocd_reachable" and request.node.failed:
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