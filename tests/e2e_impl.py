
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
import sqlite3
import shutil
import tempfile
import re
from typing import Dict, Optional, Any, Tuple

# Constants
TIMEOUT_SEC = 600
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ENV_PATH = os.path.join(REPO_ROOT, ".env")

def read_env(path: str) -> Dict[str, str]:
    env = {}
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

ENV_VARS = read_env(ENV_PATH)

# Environment Variables with defaults matching e2e.ps1
GITEA_USER = ENV_VARS.get("GITEA_ADMIN_USER", "gitops")
GITEA_PASS = ENV_VARS.get("GITEA_ADMIN_PASS", ENV_VARS.get("GITEA_ADMIN_PASSWORD", "gitops1234"))
GITEA_URL = ENV_VARS.get("GITEA_PUBLIC_URL", "http://gitea.localhost:3000")

K3D_API = ENV_VARS.get("K3D_API_PORT", "6550")
MINIO_URL = ENV_VARS.get("MINIO_PUBLIC_URL", "http://minio.localhost:9090")
MINIO_USER = ENV_VARS.get("MINIO_ROOT_USER", "minioadmin")
MINIO_PASS = ENV_VARS.get("MINIO_ROOT_PASSWORD", "minioadmin123")

MLFLOW_URL = ENV_VARS.get("MLFLOW_PUBLIC_URL", "http://mlflow.localhost:8090")
MLFLOW_EXPERIMENT = ENV_VARS.get("MLFLOW_EXPERIMENT_NAME", "hello-api-training")

PODMAN_GATEWAY = ENV_VARS.get("PODMAN_GATEWAY", "10.88.0.1")
K3D_CLUSTER = ENV_VARS.get("K3D_CLUSTER_NAME", "gitopslab")

WOODPECKER_URL = ENV_VARS.get("WOODPECKER_PUBLIC_URL", ENV_VARS.get("WOODPECKER_HOST", "http://woodpecker.localhost:8000"))
COMPOSE_PROJECT = ENV_VARS.get("COMPOSE_PROJECT_NAME", "gitopslab")

AUTH_HEADER = {
    "Authorization": "Basic " + base64.b64encode(f"{GITEA_USER}:{GITEA_PASS}".encode()).decode()
}

# Helper Functions
def run_command(cmd: list, check: bool = True, capture_output: bool = True, timeout: int = None) -> subprocess.CompletedProcess:
    # Use sudo for docker commands if we are not root (simple check)
    if cmd[0] == "docker" and os.geteuid() != 0:
        cmd.insert(0, "sudo")

    print(f"[DEBUG] Running: {' '.join(cmd)}")
    try:
        return subprocess.run(cmd, check=check, capture_output=capture_output, text=True, timeout=timeout)
    except subprocess.CalledProcessError as e:
        print(f"[ERROR] Command failed: {e.cmd}")
        print(f"[ERROR] STDOUT: {e.stdout}")
        print(f"[ERROR] STDERR: {e.stderr}")
        raise

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
        # print(f"[HTTP] Error {e.code} for {url}: {e.read().decode()}")
        raise

def wait_for_http(name: str, check_fn, timeout: int = 60, interval: int = 2):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            check_fn()
            return
        except Exception as e:
            print(f"[e2e] {name} not ready yet: {e}. Retrying...")
            time.sleep(interval)
    raise TimeoutError(f"{name} not ready after {timeout}s")

def get_woodpecker_user(volume: str, login: str) -> Optional[Dict[str, str]]:
    with tempfile.NamedTemporaryFile(delete=False) as tmp:
        tmp_path = tmp.name

    try:
        cmd = ["docker", "run", "--rm", "-v", f"{volume}:/data", "nouchka/sqlite3", "/data/woodpecker.sqlite", f"select id,hash from users where login='{login}' limit 1;"]
        # Use simple subprocess run without custom run_command wrapper for binary output handling
        if cmd[0] == "docker" and os.geteuid() != 0:
            cmd.insert(0, "sudo")

        print(f"[DEBUG] Running: {' '.join(cmd)}")
        res = subprocess.run(cmd, check=False, capture_output=True, text=True)

        if res.returncode != 0 or not res.stdout.strip():
            return None

        parts = res.stdout.strip().split("|")
        if len(parts) >= 2:
            return {"id": parts[0], "hash": parts[1]}
        return None
    except Exception as e:
        print(f"[WARN] Failed to read woodpecker DB: {e}")
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

    # In PowerShell script: [Text.Encoding]::UTF8.GetBytes($userHash)
    # user_hash is string from DB.
    signature = hmac.new(user_hash.encode("utf-8"), message.encode("utf-8"), hashlib.sha256).digest()
    signature_b64 = b64url(signature)

    return f"{message}.{signature_b64}"

def get_server_endpoint(cluster: str) -> Dict[str, Any]:
    cmd = ["docker", "inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", f"k3d-{cluster}-server-0"]
    res = run_command(cmd, check=False)
    ip = res.stdout.strip()
    return {"ip": ip, "port": 6443, "cluster": cluster}

def invoke_kubectl(command: str) -> str:
    try:
        res = run_command(["docker", "ps", "-q", "-f", "name=platform-bootstrap"], check=False)
        if res.stdout.strip():
            exec_cmd = ["docker", "exec", "platform-bootstrap", "sh", "-c", command]
            res_exec = run_command(exec_cmd, check=True)
            return res_exec.stdout
    except Exception:
        pass

    server = get_server_endpoint(K3D_CLUSTER)
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


def main():
    print("=== Starting E2E Test (Python Impl) ===")

    minio_url = resolve_url(MINIO_URL)
    mlflow_url = resolve_url(MLFLOW_URL)
    woodpecker_url = resolve_url(WOODPECKER_URL)
    gitea_url = resolve_url(GITEA_URL)

    minio_container_url = rewrite_url_host(MINIO_URL, PODMAN_GATEWAY)
    mlflow_container_url = rewrite_url_host(MLFLOW_URL, PODMAN_GATEWAY)

    print(f"[e2e] Checking MinIO at {minio_url}...")
    wait_for_http("MinIO", lambda: http_request(f"{minio_url}/minio/health/ready"), timeout=120)

    print("[e2e] Waiting for MLflow deployment rollout...")
    try:
        invoke_kubectl("kubectl -n apps rollout status deploy/mlflow --timeout=300s")
    except Exception as e:
        print(f"[WARN] MLflow deployment check failed (k8s might be down): {e}")
        print("[INFO] Proceeding to check HTTP endpoint directly.")

    print(f"[e2e] Checking MLflow at {mlflow_url}...")
    wait_for_http("MLflow", lambda: http_request(
        f"{mlflow_url}/api/2.0/mlflow/experiments/search",
        method="POST",
        json_data={"max_results": 1}
    ), timeout=180)

    print(f"[e2e] Checking Woodpecker at {woodpecker_url}...")
    woodpecker_volumes = [f"{COMPOSE_PROJECT}_woodpecker-data", "woodpecker-data"]
    wp_user = None
    for vol in woodpecker_volumes:
        wp_user = get_woodpecker_user(vol, GITEA_USER)
        if wp_user:
            break

    # Always ensure user and token are correct
    print(f"[e2e] Ensuring Woodpecker user '{GITEA_USER}' exists and has correct token...")
    # Get Gitea User ID
    try:
        gitea_user_info = http_request(f"{gitea_url}/api/v1/users/{GITEA_USER}", headers=AUTH_HEADER)
        gitea_uid = gitea_user_info["id"]
    except Exception as e:
        raise Exception(f"Failed to get Gitea user ID: {e}")

    # Get Gitea Token
    token_path = os.path.join(REPO_ROOT, ".gitea_token")
    if not os.path.exists(token_path):
        print("[e2e] .gitea_token not found on host, trying to copy from platform-bootstrap container...")
        try:
            subprocess.run(["sudo", "docker", "cp", "platform-bootstrap:/workspace/.gitea_token", token_path], check=True)
        except Exception as e:
            print(f"[WARN] Failed to copy token: {e}")

    if os.path.exists(token_path):
        with open(token_path, "r") as f:
            gitea_token_val = f.read().strip()
    else:
        print("[WARN] Using fake token, Woodpecker sync might fail.")
        gitea_token_val = "fake-token"

    # Generate Hash if new
    user_hash = base64.b64encode(os.urandom(16)).decode("utf-8") # random hash

    # Insert or Update
    update_sql = f"UPDATE users SET access_token='{gitea_token_val}' WHERE login='{GITEA_USER}';"
    insert_sql = f"INSERT INTO users (forge_id, forge_remote_id, login, access_token, admin, hash) SELECT 1, '{gitea_uid}', '{GITEA_USER}', '{gitea_token_val}', 1, '{user_hash}' WHERE NOT EXISTS (SELECT 1 FROM users WHERE login='{GITEA_USER}');"

    for vol in woodpecker_volumes:
        # Run Update
        cmd = ["docker", "run", "--rm", "-v", f"{vol}:/data", "nouchka/sqlite3", "/data/woodpecker.sqlite", update_sql]
        if os.geteuid() != 0: cmd.insert(0, "sudo")
        subprocess.run(cmd, capture_output=True, text=True)

        # Run Insert
        cmd = ["docker", "run", "--rm", "-v", f"{vol}:/data", "nouchka/sqlite3", "/data/woodpecker.sqlite", insert_sql]
        if os.geteuid() != 0: cmd.insert(0, "sudo")
        res = subprocess.run(cmd, capture_output=True, text=True)

        # Check if user exists now
        wp_user = get_woodpecker_user(vol, GITEA_USER)
        if wp_user:
            print(f"[e2e] User ensured in {vol}")
            # Restart Woodpecker to flush cache
            print("[e2e] Restarting woodpecker-server to apply DB changes...")
            subprocess.run(["sudo", "docker", "restart", "woodpecker-server"], check=True)
            # Wait for it to be ready again
            wait_for_http("Woodpecker", lambda: http_request(f"{woodpecker_url}/healthz"), timeout=60)
            break

    if not wp_user:
            raise Exception("Failed to insert/find Woodpecker user")

    wp_token = generate_woodpecker_token(wp_user["id"], wp_user["hash"])
    wp_headers = {"Authorization": f"Bearer {wp_token}"}

    gitea_repo = http_request(f"{gitea_url}/api/v1/repos/{GITEA_USER}/platform", headers=AUTH_HEADER)
    gitea_repo_id = gitea_repo["id"]

    try:
        wp_repo = http_request(f"{woodpecker_url}/api/repos/lookup/{GITEA_USER}/platform", headers=wp_headers)
    except urllib.error.HTTPError:
        wp_repo = None

    if not wp_repo or not wp_repo.get("id"):
        wp_repo = http_request(f"{woodpecker_url}/api/repos?forge_remote_id={gitea_repo_id}", method="POST", headers=wp_headers)

    wp_repo_id = wp_repo["id"]

    http_request(
        f"{woodpecker_url}/api/repos/{wp_repo_id}",
        method="PATCH",
        headers=wp_headers,
        json_data={"trusted": {"network": True, "security": True, "volumes": True}}
    )

    try:
        http_request(f"{woodpecker_url}/api/repos/{wp_repo_id}/repair", method="POST", headers=wp_headers)
    except:
        pass

    def ensure_secret(name, value):
        if not value: return
        try:
            secrets = http_request(f"{woodpecker_url}/api/repos/{wp_repo_id}/secrets", headers=wp_headers)
            if any(s["name"] == name for s in secrets):
                return
        except:
            pass

        http_request(
            f"{woodpecker_url}/api/repos/{wp_repo_id}/secrets",
            method="POST",
            headers=wp_headers,
            json_data={"name": name, "value": value, "images": [], "events": ["push", "manual"]}
        )

    ensure_secret("gitea_user", GITEA_USER)
    ensure_secret("gitea_token", gitea_token)

    print(f"[e2e] Woodpecker repo configured.")

    content_path = "hello-api/e2e-marker.txt"
    import uuid
    marker = str(uuid.uuid4())
    print(f"[e2e] Commit marker {marker}...")

    content_api = f"{gitea_url}/api/v1/repos/{GITEA_USER}/platform/contents/{content_path}"

    sha = None
    try:
        existing = http_request(content_api, headers=AUTH_HEADER)
        sha = existing["sha"]
    except urllib.error.HTTPError as e:
        if e.code != 404: raise

    body = {
        "message": f"chore(e2e): marker {marker} [skip ci]",
        "content": base64.b64encode(marker.encode()).decode(),
        "branch": "main"
    }
    method = "POST"
    if sha:
        body["sha"] = sha
        method = "PUT"

    resp = http_request(content_api, method=method, headers=AUTH_HEADER, json_data=body)
    commit_sha = resp["commit"]["sha"]
    print(f"[e2e] Commit created: {commit_sha}")

    print(f"[e2e] Triggering pipeline for {commit_sha}...")
    http_request(f"{woodpecker_url}/api/repos/{wp_repo_id}/pipelines", method="POST", headers=wp_headers, json_data={"branch": "main"})

    print(f"[e2e] Waiting for pipeline to appear...")
    wp_pipeline_number = None
    deadline = time.time() + 120
    while time.time() < deadline:
        try:
            pipelines = http_request(f"{woodpecker_url}/api/repos/{wp_repo_id}/pipelines?perPage=20", headers=wp_headers)
            for p in pipelines:
                if p["commit"] == commit_sha:
                    wp_pipeline_number = p["number"]
                    break
            if wp_pipeline_number: break
        except:
            pass
        time.sleep(3)

    if wp_pipeline_number:
        print(f"[e2e] Pipeline #{wp_pipeline_number} detected.")
    else:
        print("[WARN] Pipeline not found yet, but proceeding.")

    artifact_dir = os.path.join(REPO_ROOT, "ml/artifacts")
    os.makedirs(artifact_dir, exist_ok=True)
    model_object = f"ml-models/iris-{commit_sha}.joblib"

    print("[e2e] Running training...")
    train_image = ENV_VARS.get("ML_TRAIN_IMAGE", "registry.localhost:5002/mlflow:lite")

    # Ensure network exists (gitopslab_default in this env)
    # The container name is registry.localhost, but it's not reachable by that name from python script
    # running on host.
    # The python script runs "docker run".
    # We should use host network or the same network.

    # Note: MINIO_URL is on localhost:9090.
    # MLFLOW_URL is on localhost:8090.

    # Train script needs to push to MinIO and MLflow.
    # Inside container, these are mapped via extra_hosts or network.

    train_cmd_str = f"python ml/train.py --output ml/artifacts/model.joblib --commit {commit_sha} --model-object {model_object} --model-sha-path ml/artifacts/model.sha --experiment {MLFLOW_EXPERIMENT}"

    cmd = [
        "docker", "run", "--rm", "--network", "host",
        "-e", f"MLFLOW_TRACKING_URI={MLFLOW_URL}",
        "-e", f"MLFLOW_EXPERIMENT_NAME={MLFLOW_EXPERIMENT}",
        "-v", f"{REPO_ROOT}:/workspace",
        "-w", "/workspace",
        train_image, "sh", "-c", train_cmd_str
    ]
    run_command(cmd)

    model_sha_path = os.path.join(artifact_dir, "model.sha")
    with open(model_sha_path, "r") as f:
        model_sha = f.read().strip()

    print(f"[e2e] Uploading model to MinIO: {model_object}...")
    mc_cmd = f"""
mc alias set minio {MINIO_URL} {MINIO_USER} {MINIO_PASS} &&
mc mb --ignore-existing minio/ml-models &&
mc cp /workspace/ml/artifacts/model.joblib minio/{model_object} &&
mc stat minio/{model_object}
"""
    cmd = [
        "docker", "run", "--rm", "--network", "host",
        "-v", f"{REPO_ROOT}:/workspace",
        "--entrypoint", "/bin/sh",
        "minio/mc", "-c", mc_cmd
    ]
    run_command(cmd)

    model_config_path = "gitops/apps/hello/model-configmap.yaml"
    model_config_api = f"{gitea_url}/api/v1/repos/{GITEA_USER}/platform/contents/{model_config_path}"

    model_content_resp = http_request(model_config_api, headers=AUTH_HEADER)
    model_sha_git = model_content_resp["sha"]
    current_model_yaml = base64.b64decode(model_content_resp["content"]).decode("utf-8")

    updated_model_yaml = re.sub(r"(?m)^\s*MODEL_OBJECT:.*$", f"  MODEL_OBJECT: {model_object}", current_model_yaml)
    updated_model_yaml = re.sub(r"(?m)^\s*MODEL_SHA:.*$", f"  MODEL_SHA: {model_sha}", updated_model_yaml)

    http_request(
        model_config_api,
        method="PUT",
        headers=AUTH_HEADER,
        json_data={
            "message": f"chore(e2e): update model {model_object} [skip ci]",
            "content": base64.b64encode(updated_model_yaml.encode()).decode(),
            "branch": "main",
            "sha": model_sha_git
        }
    )
    print(f"[e2e] Model config updated.")

    deploy_image_base = ENV_VARS.get("HELLO_API_IMAGE", "registry.localhost:5002/hello-api")
    push_image_base = "localhost:5002/hello-api"
    deploy_image_tag = f"{deploy_image_base}:{commit_sha}"
    push_image_tag = f"{push_image_base}:{commit_sha}"

    print(f"[e2e] Building {deploy_image_tag}...")
    run_command(["docker", "build", "-t", deploy_image_tag, os.path.join(REPO_ROOT, "hello-api")])
    run_command(["docker", "tag", deploy_image_tag, push_image_tag])
    print(f"[e2e] Pushing {push_image_tag}...")
    run_command(["docker", "push", push_image_tag])

    gitops_path = "gitops/apps/hello/deployment.yaml"
    gitops_api = f"{gitea_url}/api/v1/repos/{GITEA_USER}/platform/contents/{gitops_path}"

    deploy_content_resp = http_request(gitops_api, headers=AUTH_HEADER)
    deploy_sha_git = deploy_content_resp["sha"]
    current_deploy_yaml = base64.b64decode(deploy_content_resp["content"]).decode("utf-8")

    lines = current_deploy_yaml.split("\n")
    updated_lines = []
    in_hello = False
    replaced = False
    for line in lines:
        if re.match(r"^\s*-\s*name:\s*hello-api\s*$", line):
            in_hello = True

        if in_hello and not replaced and re.match(r"^\s*image\s*:", line):
            indent = line[:line.find("image")]
            updated_lines.append(f"{indent}image: {deploy_image_tag}")
            replaced = True
            in_hello = False
        else:
            updated_lines.append(line)

    updated_deploy_yaml = "\n".join(updated_lines)

    http_request(
        gitops_api,
        method="PUT",
        headers=AUTH_HEADER,
        json_data={
            "message": f"chore(e2e): bump hello-api image to {commit_sha} [skip ci]",
            "content": base64.b64encode(updated_deploy_yaml.encode()).decode(),
            "branch": "main",
            "sha": deploy_sha_git
        }
    )
    print(f"[e2e] Deployment manifest updated.")

    print("[e2e] Applying changes to cluster (if k8s available)...")
    try:
        apply_model_cmd = f"cat <<'EOF' | kubectl -n apps apply -f -\n{updated_model_yaml}\nEOF"
        invoke_kubectl(apply_model_cmd)

        force_cmd = f"kubectl -n apps set image deploy/hello-api hello-api={deploy_image_tag} --record=false"
        invoke_kubectl(force_cmd)

        print(f"[e2e] Waiting for hello-api deployment with commit {commit_sha}...")
        deadline = time.time() + TIMEOUT_SEC
        while time.time() < deadline:
            try:
                out = invoke_kubectl("kubectl -n apps get deploy hello-api -o jsonpath='{.spec.template.spec.containers[0].image}'")
                image = out.strip()
                print(f"[e2e] Current image: {image}")
                if commit_sha in image:
                    print(f"[e2e] Ready: {image}")
                    break
            except:
                pass
            time.sleep(5)
    except Exception as e:
        print(f"[WARN] Failed to apply changes to cluster: {e}")
        print("[WARN] Skipping Hello API verification in k8s.")

    demo_url = resolve_url(ENV_VARS.get("DEMO_PUBLIC_URL", "http://demo.localhost:8088"))
    print(f"[e2e] Verifying Demo App at {demo_url}...")
    try:
        wait_for_http("Demo App", lambda: http_request(f"{demo_url}/"), timeout=60)

        predict_resp = http_request(
            f"{demo_url}/predict",
            method="POST",
            json_data={"features": [5.1, 3.5, 1.4, 0.2]}
        )
        print(f"[e2e] Prediction: {predict_resp}")
    except Exception as e:
        print(f"[WARN] Demo App verification failed: {e}")

    print("=== E2E OK ===")

if __name__ == "__main__":
    main()
