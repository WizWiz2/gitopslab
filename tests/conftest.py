import os
import pytest

@pytest.fixture(scope="session", autouse=True)
def load_env():
    """
    Load environment variables from a .env file at the repository root into os.environ if not already set.
    
    If a ".env" file exists one directory above this file, each non-empty, non-comment line containing "=" is parsed as KEY=VALUE and set in the environment using os.environ.setdefault (existing variables are not overwritten). Lines that are empty, start with "#" or do not contain "=" are ignored; the function does nothing if the .env file is missing.
    """
    env_path = os.path.join(os.path.dirname(__file__), "..", ".env")
    if os.path.exists(env_path):
        with open(env_path, "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())