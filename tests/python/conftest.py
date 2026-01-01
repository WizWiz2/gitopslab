import os
import pytest
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv(dotenv_path=os.path.join(os.path.dirname(__file__), '../../.env'))

@pytest.fixture(scope="session")
def env_vars():
    """Provides environment variables."""
    return {
        "GITEA_PUBLIC_URL": os.getenv("GITEA_PUBLIC_URL", "http://gitea.localhost:3000"),
        "GITEA_ADMIN_USER": os.getenv("GITEA_ADMIN_USER", "gitea_admin"),
        "GITEA_ADMIN_PASSWORD": os.getenv("GITEA_ADMIN_PASSWORD", "secret123"),
        "WOODPECKER_PUBLIC_URL": os.getenv("WOODPECKER_PUBLIC_URL", "http://woodpecker.localhost:8000"),
        "ARGOCD_PUBLIC_URL": os.getenv("ARGOCD_PUBLIC_URL", "http://argocd.localhost:8081"),
        "MLFLOW_PUBLIC_URL": os.getenv("MLFLOW_PUBLIC_URL", "http://mlflow.localhost:8090"),
        "MINIO_PUBLIC_URL": os.getenv("MINIO_PUBLIC_URL", "http://minio.localhost:9090"),
        "DEMO_APP_URL": "http://localhost:8088", # As per TechSpec
    }

def resolve_url(url):
    """
    Resolves *.localhost URLs to localhost if running outside of the docker network
    and DNS is not set up on host.
    This assumes tests are running on the host machine.
    """
    from urllib.parse import urlparse, urlunparse
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
