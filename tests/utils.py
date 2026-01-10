
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
            time.sleep(interval)
    raise TimeoutError(f"{name} not ready after {timeout}s. Last error: {last_err}")

# === Command Helpers ===

def run_command(cmd: list, check: bool = True, capture_output: bool = True, timeout: int = None) -> subprocess.CompletedProcess:
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
    # On Windows, .localhost domains don't resolve, always use localhost
    if u.hostname and u.hostname.endswith('.localhost'):
        new_netloc = f"{fallback_host}:{u.port}" if u.port else fallback_host
        return u._replace(netloc=new_netloc).geturl().rstrip("/")
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
        cmd = ["podman", "run", "--rm", "-v", f"{volume}:/data", "nouchka/sqlite3", "/data/woodpecker.sqlite", f"select id,hash,access_token from users where login='{login}' limit 1;"]
        res = subprocess.run(cmd, check=False, capture_output=True, text=True)
        if res.returncode != 0 or not res.stdout.strip():
            return None
        parts = res.stdout.strip().split("|")
        if len(parts) >= 2:
            result = {"id": parts[0], "hash": parts[1]}
            if len(parts) >= 3 and parts[2]:
                result["access_token"] = parts[2]
            return result
        return None
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)

def generate_woodpecker_token(user_id: str, user_hash: str) -> str:
    """Generate a valid JWT token for Woodpecker API using user's hash from DB.
    
    This matches the token generation in init-woodpecker.sh - the user's hash
    from the Woodpecker database is used to sign the JWT token.
    """
    
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

def perform_woodpecker_oauth_login(woodpecker_url: str, gitea_url: str, username: str, password: str) -> Optional[str]:
    """Perform Woodpecker OAuth login via Playwright browser automation and create PAT.
    
    This logs into Woodpecker via Gitea OAuth, creates a Personal Access Token (PAT),
    and returns the PAT for API authentication via x-api-key header.
    Returns PAT string if successful, None otherwise.
    """
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("[OAuth] Playwright not installed. Run: pip install playwright && python -m playwright install chromium")
        return None
    
    print(f"[OAuth] Starting browser automation for {woodpecker_url}")
    pat_token = None
    
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            context = browser.new_context()
            page = context.new_page()
            
            # Navigate to Woodpecker
            # Use 127.0.0.1 instead of localhost to avoid Windows IPv6 issues
            if "localhost" in woodpecker_url:
                woodpecker_url = woodpecker_url.replace("localhost", "127.0.0.1")
            
            print(f"[OAuth] Navigating to {woodpecker_url}")
            page.goto(woodpecker_url, timeout=60000)
            page.wait_for_load_state("networkidle")
            
            # Check if we're on login page or already logged in
            if "login" in page.url.lower():
                # Find and click login button
                try:
                    login_btn = page.locator("text=Login with gitea").first
                    if login_btn.is_visible():
                        print("[OAuth] Clicking 'Login with gitea' button")
                        login_btn.click()
                        page.wait_for_load_state("networkidle")
                except:
                    pass
                
                # Handle Gitea login page
                if "login" in page.url.lower():
                    print(f"[OAuth] On Gitea login page: {page.url}")
                    try:
                        page.fill("#user_name", username)
                        page.fill("#password", password)
                        page.click("button[type='submit'], .ui.primary.button")
                        page.wait_for_load_state("networkidle")
                        print("[OAuth] Credentials submitted")
                    except Exception as e:
                        print(f"[OAuth] Login form error: {e}")
                
                # Handle OAuth authorization page
                if "authorize" in page.url.lower():
                    print("[OAuth] On OAuth authorization page")
                    try:
                        page.click("button:has-text('Authorize'), button:has-text('Grant')")
                        page.wait_for_load_state("networkidle")
                    except:
                        pass
                
                page.wait_for_timeout(2000)
            
            # Now we should be logged in - navigate to CLI & API page to get PAT
            # Use woodpecker.localhost for proper session handling
            base_url = woodpecker_url.replace("localhost:8000", "woodpecker.localhost:8000").replace("127.0.0.1:8000", "woodpecker.localhost:8000")
            cli_api_url = f"{base_url}/user/cli-and-api"
            print(f"[OAuth] Navigating to CLI & API page: {cli_api_url}")
            page.goto(cli_api_url, timeout=60000)
            page.wait_for_load_state("networkidle")
            page.wait_for_timeout(2000)
            
            # Check if we need to re-login (session issues)
            if "login" in page.url.lower():
                print("[OAuth] Session lost, re-logging in...")
                try:
                    page.click("button:has-text('gitea')")
                    page.wait_for_load_state("networkidle")
                    page.wait_for_timeout(1000)
                except:
                    pass
                # Navigate again
                page.goto(cli_api_url, timeout=30000)
                page.wait_for_load_state("networkidle")
                page.wait_for_timeout(1000)
            
            # Look for the Personal Access Token on the page
            # Token is a JWT starting with "eyJ"
            try:
                # Get all text content and find JWT tokens
                page_content = page.content()
                import re as regex
                jwt_pattern = r'(eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)'
                jwt_matches = regex.findall(jwt_pattern, page_content)
                
                if jwt_matches:
                    pat_token = jwt_matches[0]
                    print(f"[OAuth] Found PAT token: {pat_token[:30]}...")
                else:
                    # Try looking in specific elements
                    token_elements = page.locator("code, pre, input[readonly], .token-value, span").all()
                    for el in token_elements:
                        try:
                            text = el.text_content() or el.get_attribute("value") or ""
                            if text.startswith("eyJ") and len(text) > 50:
                                pat_token = text.strip()
                                print(f"[OAuth] Found PAT in element: {pat_token[:30]}...")
                                break
                        except:
                            continue
                            
            except Exception as e:
                print(f"[OAuth] Error extracting PAT: {e}")
            
            # Check if we're on repos page (logged in successfully)
            success = "/repos" in page.url or "/user" in page.url
            print(f"[OAuth] Final URL: {page.url}, Success: {success}")
            
            browser.close()
            return pat_token
            
    except Exception as e:
        print(f"[OAuth] Error during browser automation: {e}")
        return None

# === K8s Helpers ===

def get_server_endpoint(cluster: str) -> Dict[str, Any]:
    cmd = ["podman", "inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", f"k3d-{cluster}-server-0"]
    res = run_command(cmd, check=False)
    ip = res.stdout.strip()
    return {"ip": ip, "port": 6443, "cluster": cluster}

def invoke_kubectl(command: str, cluster: str = "gitopslab") -> str:
    # Try using platform-bootstrap container if available as it has the environment setup
    res = subprocess.run(["podman", "ps", "-q", "-f", "name=platform-bootstrap"], capture_output=True, text=True)
    if res.stdout.strip():
        exec_cmd = ["podman", "exec", "platform-bootstrap", "sh", "-c", command]
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
        "podman", "run", "--rm", "--network", "podman",
        "-e", "DOCKER_HOST=unix:///var/run/podman/podman.sock",
        "-v", "/var/run/docker.sock:/var/run/podman/podman.sock",
        "gitopslab_bootstrap", "sh", "-c", run_script
    ]
    res = run_command(cmd, check=True)
    return res.stdout
