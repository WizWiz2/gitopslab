import pytest
import requests
import os
import subprocess
from urllib.parse import urlparse, urlunparse

def resolve_url(url):
    """
    Resolves *.localhost URLs to localhost if running outside of the docker network
    and DNS is not set up on host.
    This assumes tests are running on the host machine.
    """
    parsed = urlparse(url)
    if parsed.hostname and parsed.hostname.endswith('.localhost'):
        # In a real environment with proper /etc/hosts, this wouldn't be needed.
        # But if running inside the sandbox or CI without hosts entries:
        # We might need to map to localhost ports.
        # However, checking 'run-e2e.bat', it does some fallback logic.
        # For this test suite, we assume the user has set up /etc/hosts OR we rely on mapped ports.
        # Since we can't easily query mapped ports from python without docker client,
        # we'll assume the ports in .env or defaults are correct on localhost.

        # Mapping based on docker-compose.yml ports
        port_map = {
            'gitea.localhost': 3000,
            'woodpecker.localhost': 8000,
            'argocd.localhost': 8081,
            'mlflow.localhost': 8090,
            'minio.localhost': 9090,
            'demo.localhost': 8088
        }

        if parsed.hostname in port_map:
             new_netloc = f"localhost:{port_map[parsed.hostname]}"
             return urlunparse(parsed._replace(netloc=new_netloc))
    return url

def test_docker_running():
    """Verify that docker (or podman) is running."""
    # Check if we are in a sandbox environment where we might not have docker access
    # but the user asked for tests for THEIR environment.
    # So we should attempt to check, but warn if it fails.

    podman_ok = False
    try:
        subprocess.check_call(["podman", "info"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        podman_ok = True
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass

    docker_ok = False
    if not podman_ok:
        try:
            subprocess.check_call(["docker", "info"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            docker_ok = True
        except (FileNotFoundError, subprocess.CalledProcessError):
            pass

    if not podman_ok and not docker_ok:
        # In the sandbox, this is expected to fail.
        # But for the user, this is a valid test.
        # I will mark it as skipped if I detect I am in the sandbox (by checking env vars or something)
        # Or I just fail it and explain in the output.
        # For now, I'll fail it as requested by the test logic.
        pytest.fail("Neither podman nor docker is running or available.")

def test_bootstrap_script_content():
    """
    Diagnostic test: Verify that bootstrap scripts are not empty.
    The user reported issues likely due to empty scripts.
    """
    scripts_dir = os.path.join(os.path.dirname(__file__), '../../scripts')
    critical_scripts = ['bootstrap.sh', 'init-argocd.sh', 'init-gitea.sh', 'init-woodpecker.sh']

    empty_scripts = []
    for script in critical_scripts:
        path = os.path.join(scripts_dir, script)
        if not os.path.exists(path):
            empty_scripts.append(f"{script} (missing)")
        elif os.path.getsize(path) == 0:
            empty_scripts.append(f"{script} (empty)")

    if empty_scripts:
        pytest.fail(f"The following critical bootstrap scripts are empty or missing, which will prevent the platform from starting: {', '.join(empty_scripts)}")

def test_gitea_health(env_vars):
    """Check if Gitea is up."""
    url = env_vars["GITEA_PUBLIC_URL"]
    url = resolve_url(url)

    try:
        response = requests.get(f"{url}/api/v1/version", timeout=5)
        assert response.status_code == 200, f"Gitea returned status {response.status_code}"
    except requests.RequestException as e:
        pytest.fail(f"Gitea is not reachable at {url}: {e}")

def test_woodpecker_health(env_vars):
    """Check if Woodpecker is up."""
    url = env_vars["WOODPECKER_PUBLIC_URL"]
    url = resolve_url(url)

    try:
        response = requests.get(f"{url}/healthz", timeout=5)
        assert response.status_code == 200, f"Woodpecker returned status {response.status_code}"
    except requests.RequestException as e:
        pytest.fail(f"Woodpecker is not reachable at {url}: {e}")

def test_argocd_health(env_vars):
    """Check if ArgoCD is up."""
    url = env_vars["ARGOCD_PUBLIC_URL"]
    url = resolve_url(url)

    try:
        # ArgoCD usually redirects to /login or returns 200 on healthz
        # Using verify=False because self-signed certs are likely
        # Suppress warnings for cleaner output
        requests.packages.urllib3.disable_warnings()
        response = requests.get(f"{url}/healthz", timeout=5, verify=False)
        assert response.status_code == 200, f"ArgoCD returned status {response.status_code}"
    except requests.RequestException as e:
        pytest.fail(f"ArgoCD is not reachable at {url}. This might be because the bootstrap process failed. Error: {e}")

def test_minio_health(env_vars):
    """Check if MinIO is up."""
    url = env_vars["MINIO_PUBLIC_URL"]
    url = resolve_url(url)

    try:
        response = requests.get(f"{url}/minio/health/live", timeout=5)
        assert response.status_code == 200, f"MinIO returned status {response.status_code}"
    except requests.RequestException as e:
        pytest.fail(f"MinIO is not reachable at {url}: {e}")

def test_mlflow_health(env_vars):
    """Check if MLflow is up."""
    url = env_vars["MLFLOW_PUBLIC_URL"]
    url = resolve_url(url)

    try:
        response = requests.get(f"{url}/health", timeout=5)
        assert response.status_code == 200, f"MLflow returned status {response.status_code}"
    except requests.RequestException as e:
        pytest.fail(f"MLflow is not reachable at {url}: {e}")
