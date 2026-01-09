
import os
import sys
import time
import json
import subprocess
import base64
import hashlib
import hmac
import urllib.request
import urllib.error
import tempfile
import re
from typing import Dict, Optional, Any, Callable

# === Configuration ===

def get_repo_root():
    return os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

def read_env() -> Dict[str, str]:
    env = {}
    path = os.path.join(get_repo_root(), ".env")
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

ENV_VARS = read_env()

# === HTTP Helpers ===

def http_request(url: str, method: str = "GET", headers: Dict = None, data: Any = None, json_data: Any = None) -> Any:
    if json_data:
        data = json.dumps(json_data).encode("utf-8")
        if headers is None: headers = {}
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, method=method, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(req) as resp:
            content = resp.read()
            if resp.headers.get_content_type() == "application/json":
                return json.loads(content)
            return content
    except urllib.error.HTTPError as e:
        # Re-raise with more context if possible, or let caller handle
        # Adding body to exception message for debugging
        error_body = e.read().decode('utf-8', errors='ignore')
        print(f"[HTTP] {method} {url} -> {e.code}: {error_body}")
        raise

def wait_for_http(name: str, check_fn: Callable[[], Any], timeout: int = 60, interval: int = 2):
    deadline = time.time() + timeout
    last_err = None
    while time.time() < deadline:
        try:
            return check_fn()
        except Exception as e:
            last_err = e
            # print(f"[wait] {name}: {e}")
            time.sleep(interval)
    raise TimeoutError(f"{name} not ready after {timeout}s. Last error: {last_err}")

# === Command Helpers ===

def run_command(cmd: list, check: bool = True, capture_output: bool = True, timeout: int = None) -> subprocess.CompletedProcess:
    if cmd[0] == "docker" and os.name != 'nt' and os.geteuid() != 0:
        cmd.insert(0, "sudo")

    print(f"[CMD] {' '.join(cmd)}")
    try:
        return subprocess.run(cmd, check=check, capture_output=capture_output, text=True, timeout=timeout)
    except subprocess.CalledProcessError as e:
        print(f"[CMD] Failed: {e.cmd}")
        print(f"[CMD] STDOUT: {e.stdout}")
        print(f"[CMD] STDERR: {e.stderr}")
        raise

# === URL Helpers ===

def resolve_url(url: str, fallback_host: str = "localhost") -> str:
    from urllib.parse import urlparse
    u = urlparse(url)
    try:
        import socket
        socket.gethostbyname(u.hostname)
        return url.rstrip("/")
    except:
        new_netloc = f"{fallback_host}:{u.port}" if u.port else fallback_host
        return u._replace(netloc=new_netloc).geturl().rstrip("/")

def rewrite_url_host(url: str, target_host: str) -> str:
    from urllib.parse import urlparse
    u = urlparse(url)
    new_netloc = f"{target_host}:{u.port}" if u.port else target_host
    return u._replace(netloc=new_netloc).geturl().rstrip("/")

# === Woodpecker / Gitea Helpers ===

def get_woodpecker_user(volume: str, login: str) -> Optional[Dict[str, str]]:
    with tempfile.NamedTemporaryFile(delete=False) as tmp:
        tmp_path = tmp.name
    try:
        cmd = ["docker", "run", "--rm", "-v", f"{volume}:/data", "nouchka/sqlite3", "/data/woodpecker.sqlite", f"select id,hash from users where login='{login}' limit 1;"]
        if cmd[0] == "docker" and os.name != 'nt' and os.geteuid() != 0:
            cmd.insert(0, "sudo")
        
        # print(f"[DEBUG] DB Query: {cmd}")
        res = subprocess.run(cmd, check=False, capture_output=True, text=True)
        if res.returncode != 0 or not res.stdout.strip():
            return None
        parts = res.stdout.strip().split("|")
        if len(parts) >= 2:
            return {"id": parts[0], "hash": parts[1]}
        return None
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)

def generate_woodpecker_token(user_id: str, user_hash: str) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    payload = {
        "user-id": int(user_id),
        "type": "user",
        "exp": int(time.time() + 3600)
    }
    def b64url(b: bytes) -> str:
        return base64.urlsafe_b64encode(b).rstrip(b"=").decode("utf-8")
    
    header_b64 = b64url(json.dumps(header, separators=(',', ':')).encode("utf-8"))
    payload_b64 = b64url(json.dumps(payload, separators=(',', ':')).encode("utf-8"))
    message = f"{header_b64}.{payload_b64}"
    signature = hmac.new(user_hash.encode("utf-8"), message.encode("utf-8"), hashlib.sha256).digest()
    return f"{message}.{b64url(signature)}"

# === K8s Helpers ===

def get_server_endpoint(cluster: str) -> Dict[str, Any]:
    cmd = ["docker", "inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", f"k3d-{cluster}-server-0"]
    res = run_command(cmd, check=False)
    ip = res.stdout.strip()
    return {"ip": ip, "port": 6443, "cluster": cluster}

def invoke_kubectl(command: str, cluster: str = "gitopslab") -> str:
    # Try using platform-bootstrap container if available as it has the environment setup
    res = subprocess.run(["docker", "ps", "-q", "-f", "name=platform-bootstrap"], capture_output=True, text=True)
    if res.stdout.strip():
        exec_cmd = ["docker", "exec", "platform-bootstrap", "sh", "-c", command]
        res_exec = run_command(exec_cmd, check=True)
        return res_exec.stdout

    # Fallback to ephemeral container
    server = get_server_endpoint(cluster)
    if not server["ip"]:
        raise Exception("Could not find k3d server IP")

    run_script = f"""
set -e
export DOCKER_HOST=unix:///var/run/podman/podman.sock
mkdir -p /root/.kube
k3d kubeconfig get {server['cluster']} > /root/.kube/config
sed -i 's|https://0.0.0.0:[0-9]*|https://127.0.0.1:{server['port']}|g' /root/.kube/config
sed -i 's|https://localhost:[0-9]*|https://127.0.0.1:{server['port']}|g' /root/.kube/config
sed -i 's|127.0.0.1|{server['ip']}|g' /root/.kube/config
{command}
"""
    cmd = [
        "docker", "run", "--rm", "--network", "podman",
        "-e", "DOCKER_HOST=unix:///var/run/podman/podman.sock",
        "-v", "/var/run/docker.sock:/var/run/podman/podman.sock",
        "gitopslab_bootstrap", "sh", "-c", run_script
    ]
    res = run_command(cmd, check=True)
    return res.stdout
