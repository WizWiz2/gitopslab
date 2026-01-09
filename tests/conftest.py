import os
import pytest

@pytest.fixture(scope="session", autouse=True)
def load_env():
    env_path = os.path.join(os.path.dirname(__file__), "..", ".env")
    if os.path.exists(env_path):
        with open(env_path, "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())

@pytest.hookimpl(tryfirst=True, hookwrapper=True)
def pytest_runtest_makereport(item, call):
    # Execute all other hooks to obtain the report object
    outcome = yield
    report = outcome.get_result()

    if report.when == "call" and report.failed:
        print(f"\n[FAILURE] Test {item.name} failed. Attempting diagnostics...")
        # Check if it looks like a specific service failure based on test name
        if "woodpecker" in item.name.lower():
            dump_logs("woodpecker-server")
            dump_logs("woodpecker-agent")
        elif "argocd" in item.name.lower():
             dump_logs("argocd") # might need specific container name
        elif "gitea" in item.name.lower():
            dump_logs("gitea")
        
        # Always dump last few lines of platform-bootstrap if relevant
        dump_logs("platform-bootstrap", tail=20)

import subprocess

def dump_logs(container_name: str, tail: int = 50):
    try:
        print(f"[LOGS] --- {container_name} (last {tail} lines) ---")
        cmd = ["docker", "logs", "--tail", str(tail), container_name]
        if os.name != 'nt' and os.geteuid() != 0:
            cmd.insert(0, "sudo")
        subprocess.run(cmd, check=False)
        print(f"[LOGS] --- End {container_name} ---")
    except Exception:
        pass

