<#
E2E flow: commit in Gitea -> build in Woodpecker -> deploy in ArgoCD -> validate hello-api.
Requirements: platform already running, Woodpecker pods are trusted, podman available.
#>
param(
    [int]$TimeoutSec = 600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding

$repoRoot = Split-Path -Parent $PSCommandPath
$envPath = Join-Path (Join-Path $repoRoot "..") ".env"
if (-not (Test-Path $envPath)) { throw ".env file not found: $envPath" }

# Load .env
$envVars = @{}
Get-Content $envPath | ForEach-Object {
    if ($_ -match "^\s*#") { return }
    if ($_ -match "=") {
        $parts = $_.Split("=", 2)
        $envVars[$parts[0].Trim()] = $parts[1].Trim()
    }
}

$giteaUser = $envVars["GITEA_ADMIN_USER"]
$giteaPass = $envVars["GITEA_ADMIN_PASS"]
if (-not $giteaPass) { $giteaPass = $envVars["GITEA_ADMIN_PASSWORD"] }
$giteaUrl  = $envVars["GITEA_PUBLIC_URL"]
$k3dApi    = $envVars["K3D_API_PORT"]
if (-not $k3dApi) { $k3dApi = "6550" }
$minioUrl = $envVars["MINIO_PUBLIC_URL"]
if (-not $minioUrl) { $minioUrl = "http://minio.localhost:9090" }
$minioUser = $envVars["MINIO_ROOT_USER"]
if (-not $minioUser) { $minioUser = "minioadmin" }
$minioPass = $envVars["MINIO_ROOT_PASSWORD"]
if (-not $minioPass) { $minioPass = "minioadmin123" }
$mlflowUrl = $envVars["MLFLOW_PUBLIC_URL"]
if (-not $mlflowUrl) { $mlflowUrl = "http://mlflow.localhost:8090" }
$mlflowExperiment = $envVars["MLFLOW_EXPERIMENT_NAME"]
if (-not $mlflowExperiment) { $mlflowExperiment = "hello-api-training" }
$podmanGateway = $envVars["PODMAN_GATEWAY"]
if (-not $podmanGateway) { $podmanGateway = "10.88.0.1" }

if (-not $giteaUser -or -not $giteaPass -or -not $giteaUrl) {
    throw "Missing Gitea user/password/URL in .env"
}

function Resolve-Url {
    param([string]$url, [string]$fallbackHost)
    $uri = [Uri]$url
    try {
        [System.Net.Dns]::GetHostEntry($uri.Host) | Out-Null
        return $url.TrimEnd("/")
    } catch {
        $builder = New-Object UriBuilder $uri
        $builder.Host = $fallbackHost
        return $builder.Uri.AbsoluteUri.TrimEnd("/")
    }
}

function Rewrite-UrlHost {
    param([string]$url, [string]$host)
    $uri = [Uri]$url
    $builder = New-Object UriBuilder $uri
    $builder.Host = $host
    return $builder.Uri.AbsoluteUri.TrimEnd("/")
}

# Fallback in case gitea.localhost is not resolvable
try {
    $u = [Uri]$giteaUrl
    [System.Net.Dns]::GetHostEntry($u.Host) | Out-Null
} catch {
    $u = [Uri]$giteaUrl
    $giteaUrl = "http://localhost:$($u.Port)"
    Write-Host "[e2e] gitea.localhost is not resolvable, fallback to $giteaUrl"
}

$minioUrl = Resolve-Url -url $minioUrl -fallbackHost "localhost"
$mlflowUrl = Resolve-Url -url $mlflowUrl -fallbackHost "localhost"
$minioContainerUrl = Rewrite-UrlHost -url $minioUrl -host $podmanGateway
$mlflowContainerUrl = Rewrite-UrlHost -url $mlflowUrl -host $podmanGateway

Write-Host "[e2e] Checking MinIO at $minioUrl ..."
Invoke-WebRequest -Uri "$minioUrl/minio/health/ready" -UseBasicParsing -ErrorAction Stop | Out-Null
Write-Host "[e2e] Checking MLflow at $mlflowUrl ..."
Invoke-RestMethod -Method Get -Uri "$mlflowUrl/api/2.0/mlflow/experiments/list" -ErrorAction Stop | Out-Null

$contentPath = "hello-api/e2e-marker.txt"
$marker = [Guid]::NewGuid().ToString("N")

Write-Host "[e2e] Commit marker $marker into $contentPath ..."

$authHeader = @{
    Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$giteaUser`:$giteaPass"))
}

$body = @{
    message = "chore(e2e): marker $marker"
    content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($marker))
    branch  = "main"
}

$contentApiUrl = "$giteaUrl/api/v1/repos/$giteaUser/platform/contents/$contentPath"

function Get-ExistingSha {
    try {
        $existing = Invoke-RestMethod -Method Get -Uri $contentApiUrl -Headers $authHeader -ErrorAction Stop
        return $existing.sha
    } catch {
        $response = $_.Exception.Response
        if ($response -and $response.StatusCode.value__ -eq 404) { return $null }
        throw
    }
}

$existingSha = Get-ExistingSha
$method = "Post"
if ($existingSha) {
    $method = "Put"
    $body.sha = $existingSha
}

function Send-Content {
    param($method, $body)
    $json = $body | ConvertTo-Json
    return Invoke-RestMethod -Method $method -Uri $contentApiUrl -Headers $authHeader -ContentType "application/json" -Body $json
}

try {
    $resp = Send-Content -method $method -body $body
} catch {
    $details = $_.ErrorDetails.Message
    $existingSha = Get-ExistingSha
    if ($details -like "*SHA*Required*" -or $details -like "*already exists*" -or $existingSha) {
        if (-not $existingSha) { throw }
        $body.sha = $existingSha
        $resp = Send-Content -method "Put" -body $body
    } else { throw }
}
$commitSha = $resp.commit.sha
Write-Host "[e2e] Commit created: $commitSha"

$artifactDir = Join-Path (Join-Path $repoRoot "..") "ml\\artifacts"
New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
$modelObject = "ml-models/iris-$commitSha.joblib"

Write-Host "[e2e] Training model and logging to MLflow ($mlflowUrl) ..."
$trainCmd = @(
    "pip install --no-cache-dir -r ml/requirements.txt"
    "python ml/train.py --output ml/artifacts/model.joblib --commit $commitSha --model-object $modelObject --model-sha-path ml/artifacts/model.sha --experiment $mlflowExperiment"
) -join " && "
podman run --rm --network podman `
    --add-host "mlflow.localhost:$podmanGateway" `
    -e "MLFLOW_TRACKING_URI=$mlflowContainerUrl" `
    -e "MLFLOW_EXPERIMENT_NAME=$mlflowExperiment" `
    -v "$((Join-Path $repoRoot "..")):/workspace" `
    -w /workspace `
    python:3.10-slim sh -c $trainCmd | Out-Null

$modelShaPath = Join-Path $artifactDir "model.sha"
if (-not (Test-Path $modelShaPath)) { throw "Model sha not found at $modelShaPath" }
$modelSha = (Get-Content $modelShaPath | Select-Object -First 1).Trim()

Write-Host "[e2e] Uploading model to MinIO: $modelObject ..."
$mcCmd = @(
    "mc alias set minio $minioContainerUrl $minioUser $minioPass"
    "mc mb --ignore-existing minio/ml-models"
    "mc cp /workspace/ml/artifacts/model.joblib minio/$modelObject"
    "mc stat minio/$modelObject"
) -join " && "
podman run --rm --network podman `
    --add-host "minio.localhost:$podmanGateway" `
    -v "$((Join-Path $repoRoot "..")):/workspace" `
    minio/mc sh -c $mcCmd | Out-Null

$modelConfigPath = "gitops/apps/hello/model-configmap.yaml"
$modelConfigUrl  = "$giteaUrl/api/v1/repos/$giteaUser/platform/contents/$modelConfigPath"
$modelContent = Invoke-RestMethod -Method Get -Uri $modelConfigUrl -Headers $authHeader -ErrorAction Stop
$modelShaGit = $modelContent.sha
$currentModelYaml = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($modelContent.content))
$updatedModelYaml = $currentModelYaml -replace "(?m)^\\s*MODEL_OBJECT:.*$", "  MODEL_OBJECT: $modelObject"
$updatedModelYaml = $updatedModelYaml -replace "(?m)^\\s*MODEL_SHA:.*$", "  MODEL_SHA: $modelSha"
$modelBody = @{
    message = "chore(e2e): update model $modelObject"
    content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($updatedModelYaml))
    branch  = "main"
    sha     = $modelShaGit
} | ConvertTo-Json
Invoke-RestMethod -Method Put -Uri $modelConfigUrl -Headers $authHeader -ContentType "application/json" -Body $modelBody -ErrorAction Stop | Out-Null
Write-Host "[e2e] Model config updated with $modelObject ($modelSha)"

$experimentNameEsc = [Uri]::EscapeDataString($mlflowExperiment)
$experiment = Invoke-RestMethod -Method Get -Uri "$mlflowUrl/api/2.0/mlflow/experiments/get-by-name?experiment_name=$experimentNameEsc" -ErrorAction Stop
$expId = $experiment.experiment.experiment_id
$searchBody = @{
    experiment_ids = @($expId)
    filter = "tag.commit_sha = '$commitSha'"
    max_results = 1
    order_by = @("start_time DESC")
} | ConvertTo-Json
$runResp = Invoke-RestMethod -Method Post -Uri "$mlflowUrl/api/2.0/mlflow/runs/search" -ContentType "application/json" -Body $searchBody -ErrorAction Stop
if (-not $runResp.runs -or $runResp.runs.Count -eq 0) {
    throw "MLflow run not found for commit $commitSha"
}
$run = $runResp.runs[0]
if ($run.info.status -ne "FINISHED") {
    throw "MLflow run status is $($run.info.status)"
}
$mlflowRunUrl = "$mlflowUrl/#/experiments/$expId/runs/$($run.info.run_id)"
Write-Host "[e2e] MLflow run: $mlflowRunUrl"

$deployImageBase = $envVars["HELLO_API_IMAGE"]
if (-not $deployImageBase -or $deployImageBase -eq "localhost:5000/hello-api") {
    $deployImageBase = "registry.localhost:5002/hello-api"
}
$pushImageBase = "localhost:5002/hello-api"
$deployImageTag = "${deployImageBase}:$commitSha"
$pushImageTag   = "${pushImageBase}:$commitSha"

Write-Host "[e2e] Building image $deployImageTag ..."
podman build -t $deployImageTag hello-api | Out-Null
podman tag $deployImageTag $pushImageTag | Out-Null
Write-Host "[e2e] Pushing image via $pushImageTag ..."
podman push --tls-verify=false $pushImageTag | Out-Null

$gitopsPath = "gitops/apps/hello/deployment.yaml"
$gitopsUrl  = "$giteaUrl/api/v1/repos/$giteaUser/platform/contents/$gitopsPath"
$deployContent = Invoke-RestMethod -Method Get -Uri $gitopsUrl -Headers $authHeader -ErrorAction Stop
$deploySha = $deployContent.sha
$currentYaml = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($deployContent.content))
$updatedYaml = $currentYaml -replace "(?m)^\\s*image:\\s*.+$", "          image: $deployImageTag"
$beforeLine = ($currentYaml -split "`n" | Where-Object { $_ -match "^\\s*image\\s*:" }) -join "; "
Write-Host "[e2e] Updating deployment image: $beforeLine -> image: $deployImageTag"
$deployBody = @{
    message = "chore(e2e): bump hello-api image to $commitSha"
    content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($updatedYaml))
    branch  = "main"
    sha     = $deploySha
} | ConvertTo-Json
Invoke-RestMethod -Method Put -Uri $gitopsUrl -Headers $authHeader -ContentType "application/json" -Body $deployBody -ErrorAction Stop | Out-Null
Write-Host "[e2e] Deployment manifest updated with $deployImageTag"

$deadline = (Get-Date).AddSeconds($TimeoutSec)

function Get-ServerEndpoint {
    param([string]$cluster="gitopslab")
    $serverIp = podman inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" "k3d-$cluster-server-0" 2>$null
    $serverIp = $serverIp.Trim()
    return @{ ip = $serverIp; port = 6443 }
}

$server = Get-ServerEndpoint
if (-not $server.ip) { throw "Could not find k3d server IP" }

$kubectlBase = @(
    "set -e"
    "export DOCKER_HOST=unix:///var/run/podman/podman.sock"
    "mkdir -p /root/.kube"
    "k3d kubeconfig get gitopslab > /root/.kube/config"
    "sed -i 's|https://0.0.0.0:[0-9]*|https://127.0.0.1:$($server.port)|g' /root/.kube/config"
    "sed -i 's|https://localhost:[0-9]*|https://127.0.0.1:$($server.port)|g' /root/.kube/config"
    "sed -i 's|127.0.0.1|$($server.ip)|g' /root/.kube/config"
)
$applyModelCmd = ($kubectlBase + @(
    "cat <<'EOF' | kubectl -n apps apply -f -"
    $updatedModelYaml
    "EOF"
)) -join "`n"
Write-Host "[e2e] Applying model config to cluster ..."
podman run --rm --network podman `
    -e DOCKER_HOST=unix:///var/run/podman/podman.sock `
    -v /var/run/podman/podman.sock:/var/run/podman/podman.sock `
    gitopslab_bootstrap sh -c $applyModelCmd | Out-Null
$forceCmd = ($kubectlBase + "kubectl -n apps set image deploy/hello-api hello-api=$deployImageTag --record=false") -join "`n"
Write-Host "[e2e] Forcing deployment image to $deployImageTag ..."
podman run --rm --network podman `
    -e DOCKER_HOST=unix:///var/run/podman/podman.sock `
    -v /var/run/podman/podman.sock:/var/run/podman/podman.sock `
    gitopslab_bootstrap sh -c $forceCmd | Out-Null

function Get-ImageTag {
    param($serverIp, $serverPort)
    $cmdLines = @(
        "set -e"
        "export DOCKER_HOST=unix:///var/run/podman/podman.sock"
        "mkdir -p /root/.kube"
        "k3d kubeconfig get gitopslab > /root/.kube/config"
        "sed -i 's|https://0.0.0.0:[0-9]*|https://127.0.0.1:$serverPort|g' /root/.kube/config"
        "sed -i 's|https://localhost:[0-9]*|https://127.0.0.1:$serverPort|g' /root/.kube/config"
        "sed -i 's|127.0.0.1|$serverIp|g' /root/.kube/config"
        "kubectl -n apps get deploy hello-api -o jsonpath='{.spec.template.spec.containers[0].image}'"
    )
    $cmd = ($cmdLines -join "`n")
    $out = podman run --rm --network podman `
        -e DOCKER_HOST=unix:///var/run/podman/podman.sock `
        -v /var/run/podman/podman.sock:/var/run/podman/podman.sock `
        gitopslab_bootstrap sh -c $cmd
    return $out.Trim()
}

Write-Host "[e2e] Waiting for hello-api deployment with commit $commitSha ..."
while ($true) {
    if ((Get-Date) -gt $deadline) { throw "Timed out waiting for hello-api deployment with commit $commitSha" }
    try {
        $image = Get-ImageTag -serverIp $server.ip -serverPort $server.port
        Write-Host "[e2e] image: $image"
        if ($image -like "*$commitSha") {
            Write-Host "[e2e] Ready: deployment uses commit $commitSha"
            break
        }
    } catch {
        Write-Host "[e2e] retry after error: $_"
    }
    Start-Sleep -Seconds 5
}

$demoBase = "http://demo.localhost:8088"
try {
    $resp = Invoke-WebRequest -Uri $demoBase -UseBasicParsing -ErrorAction Stop
} catch {
    $demoBase = "http://localhost:8088"
    $resp = Invoke-WebRequest -Uri $demoBase -UseBasicParsing -ErrorAction Stop
}
Write-Host "[e2e] Demo app status: $($resp.StatusCode)"
$predictBody = @{ features = @(5.1, 3.5, 1.4, 0.2) } | ConvertTo-Json
$predict = Invoke-RestMethod -Method Post -Uri "$demoBase/predict" -ContentType "application/json" -Body $predictBody -ErrorAction Stop
Write-Host "[e2e] Predict: class $($predict.class_id) ($($predict.class_name))"
Write-Host "[e2e] MLflow UI: $mlflowUrl"
Write-Host "[e2e] MLflow Run: $mlflowRunUrl"
Write-Host "=== E2E OK ==="
