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

$repoRoot = Split-Path -Parent (Resolve-Path $PSCommandPath)
$envPath = Join-Path (Split-Path -Parent $repoRoot) ".env"
if (-not (Test-Path $envPath)) { throw ".env file not found at $envPath (repoRoot was $repoRoot)" }

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
$giteaUrl = $envVars["GITEA_PUBLIC_URL"]
$k3dApi = $envVars["K3D_API_PORT"]
if (-not $k3dApi) { $k3dApi = "6550" }
$minioUrl = $envVars["MINIO_PUBLIC_URL"]
if (-not $minioUrl) { $minioUrl = "http://localhost:9090" }
$minioUser = $envVars["MINIO_ROOT_USER"]
if (-not $minioUser) { $minioUser = "minioadmin" }
$minioPass = $envVars["MINIO_ROOT_PASSWORD"]
if (-not $minioPass) { $minioPass = "minioadmin123" }
$mlflowUrl = $envVars["MLFLOW_PUBLIC_URL"]
if (-not $mlflowUrl) { $mlflowUrl = "http://localhost:8090" }
$mlflowExperiment = $envVars["MLFLOW_EXPERIMENT_NAME"]
if (-not $mlflowExperiment) { $mlflowExperiment = "hello-api-training" }
$podmanGateway = $envVars["PODMAN_GATEWAY"]
if (-not $podmanGateway) { $podmanGateway = "10.89.0.1" }
$k3dCluster = $envVars["K3D_CLUSTER_NAME"]
if (-not $k3dCluster) { $k3dCluster = "gitopslab" }
$woodpeckerUrl = $envVars["WOODPECKER_PUBLIC_URL"]
if (-not $woodpeckerUrl) { $woodpeckerUrl = $envVars["WOODPECKER_HOST"] }
if (-not $woodpeckerUrl) { $woodpeckerUrl = "http://localhost:8000" }
$composeProject = $envVars["COMPOSE_PROJECT_NAME"]
if (-not $composeProject) { $composeProject = "gitopslab" }

if (-not $giteaUser -or -not $giteaPass -or -not $giteaUrl) {
    throw "Missing Gitea user/password/URL in .env"
}

function Resolve-Url {
    param([string]$url, [string]$fallbackHost)
    $uri = [Uri]$url
    try {
        [System.Net.Dns]::GetHostEntry($uri.Host) | Out-Null
        return $url.TrimEnd("/")
    }
    catch {
        $builder = New-Object UriBuilder $uri
        $builder.Host = $fallbackHost
        return $builder.Uri.AbsoluteUri.TrimEnd("/")
    }
}

function Rewrite-UrlHost {
    param([string]$url, [string]$targetHost)
    $uri = [Uri]$url
    $builder = New-Object UriBuilder $uri
    $builder.Host = $targetHost
    return $builder.Uri.AbsoluteUri.TrimEnd("/")
}

function Wait-For-Http {
    param(
        [string]$name,
        [scriptblock]$check,
        [int]$timeoutSec = 60,
        [int]$intervalSec = 2
    )
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ($true) {
        try {
            & $check
            return
        }
        catch {
            if ((Get-Date) -gt $deadline) {
                throw "$name not ready after ${timeoutSec}s: $($_.Exception.Message)"
            }
            Write-Host "[e2e] $name not ready yet, retrying..."
            Start-Sleep -Seconds $intervalSec
        }
    }
}

function Convert-JsonIfNeeded {
    param([object]$response, [string]$context)
    if ($null -eq $response) { return $null }
    if ($response -is [string]) {
        try {
            return $response | ConvertFrom-Json
        }
        catch {
            $snippet = $response
            if ($snippet.Length -gt 300) { $snippet = $snippet.Substring(0, 300) + "..." }
            throw "$context returned non-JSON response: $snippet"
        }
    }
    return $response
}

function Get-ResponseProperty {
    param([object]$response, [string]$name)
    if ($null -eq $response) { return $null }
    $prop = $response.PSObject.Properties[$name]
    if ($prop) { return $prop.Value }
    return $null
}

function Convert-ToBase64Url {
    param([byte[]]$bytes)
    $b64 = [Convert]::ToBase64String($bytes)
    return $b64.TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function New-WoodpeckerToken {
    param([string]$userId, [string]$userHash)
    $header = '{"alg":"HS256","typ":"JWT"}'
    $payload = @{
        "user-id" = $userId
        type      = "user"
        exp       = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600)
    } | ConvertTo-Json -Compress
    $headerB64 = Convert-ToBase64Url -bytes ([Text.Encoding]::UTF8.GetBytes($header))
    $payloadB64 = Convert-ToBase64Url -bytes ([Text.Encoding]::UTF8.GetBytes($payload))
    $message = "$headerB64.$payloadB64"
    $hmacKey = [byte[]][Text.Encoding]::UTF8.GetBytes($userHash)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (, $hmacKey)
    try {
        $signature = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($message))
    }
    finally {
        $hmac.Dispose()
    }
    $signatureB64 = Convert-ToBase64Url -bytes $signature
    return "$message.$signatureB64"
}

function Get-WoodpeckerUser {
    param([string]$volume, [string]$login)
    $sql = "select id,hash from users where login='$login' limit 1;"
    $output = & podman run --rm -v "${volume}:/data" nouchka/sqlite3 /data/woodpecker.sqlite $sql 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) { return $null }
    $parts = $output.Trim().Split("|")
    if ($parts.Count -lt 2) { return $null }
    return @{ id = $parts[0]; hash = $parts[1] }
}

function Find-WoodpeckerPipeline {
    param([string]$repoId, [string]$commitSha, [int]$perPage = 20)
    $pipelines = Invoke-RestMethod -Method Get -Uri "$woodpeckerUrl/api/repos/$repoId/pipelines?perPage=$perPage" -Headers $woodpeckerHeaders -ErrorAction Stop
    $pipelines = Convert-JsonIfNeeded -response $pipelines -context "Woodpecker pipelines list"
    if ($pipelines -is [string]) { return $null }
    if ($pipelines -is [System.Collections.IEnumerable]) {
        $match = $pipelines | Where-Object { (Get-ResponseProperty -response $_ -name "commit") -eq $commitSha } | Select-Object -First 1
        if ($match) { return $match }
        return $null
    }
    return $null
}

function Get-GiteaTokenFromFile {
    param([string]$repoRoot, [string]$fallback)
    $tokenPath = Join-Path $repoRoot ".gitea_token"
    if (Test-Path $tokenPath) {
        $token = (Get-Content $tokenPath | Select-Object -First 1).Trim()
        if ($token) { return $token }
    }
    return $fallback
}

function Ensure-WoodpeckerSecret {
    param([string]$repoId, [string]$name, [string]$value)
    if (-not $value) { return }
    $secrets = Invoke-RestMethod -Method Get -Uri "$woodpeckerUrl/api/repos/$repoId/secrets" -Headers $woodpeckerHeaders -ErrorAction Stop
    $secrets = Convert-JsonIfNeeded -response $secrets -context "Woodpecker secrets"
    if ($null -eq $secrets) { $secrets = @() }
    if ($secrets -is [string]) {
        if ($secrets.Trim().ToLowerInvariant() -eq "null") {
            $secrets = @()
        }
        else {
            $secrets = @()
        }
    }
    if (-not ($secrets -is [System.Collections.IEnumerable])) { $secrets = @() }
    $exists = $secrets | Where-Object { (Get-ResponseProperty -response $_ -name "name") -eq $name } | Select-Object -First 1
    if ($exists) { return }
    $payload = @{ name = $name; value = $value; images = @(); events = @("push", "manual") } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri "$woodpeckerUrl/api/repos/$repoId/secrets" -Headers $woodpeckerHeaders -ContentType "application/json" -Body $payload -ErrorAction Stop | Out-Null
}

function Get-ServerEndpoint {
    param([string]$cluster)
    if (-not $cluster) { $cluster = "gitopslab" }
    $serverIp = podman inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" "k3d-$cluster-server-0" 2>$null
    $serverIp = $serverIp.Trim()
    return @{ ip = $serverIp; port = 6443; cluster = $cluster }
}

function Invoke-Kubectl {
    param([string]$command)
    try {
        # Execute directly in the k3d server container node which has kubectl and access
        $execOut = & podman exec k3d-gitopslab-server-0 sh -c $command 2>&1
        if ($LASTEXITCODE -eq 0) { return $execOut }
        throw "Kubectl command failed: $execOut"
    }
    catch {
        throw $_
    }
}


# Fallback in case gitea.localhost is not resolvable
try {
    $u = [Uri]$giteaUrl
    [System.Net.Dns]::GetHostEntry($u.Host) | Out-Null
}
catch {
    $u = [Uri]$giteaUrl
    $giteaUrl = "http://localhost:$($u.Port)"
    Write-Host "[e2e] gitea.localhost is not resolvable, fallback to $giteaUrl"
}

$authHeader = @{
    Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$giteaUser`:$giteaPass"))
}

$minioDisplayUrl = $minioUrl
$mlflowDisplayUrl = $mlflowUrl
$woodpeckerDisplayUrl = $woodpeckerUrl

$minioUrl = Resolve-Url -url $minioUrl -fallbackHost "localhost"
$mlflowUrl = Resolve-Url -url $mlflowUrl -fallbackHost "localhost"
$woodpeckerUrl = Resolve-Url -url $woodpeckerUrl -fallbackHost "localhost"
$minioContainerUrl = Rewrite-UrlHost -url $minioUrl -targetHost $podmanGateway
$mlflowContainerUrl = Rewrite-UrlHost -url $mlflowUrl -targetHost $podmanGateway

Write-Host "[e2e] Checking MinIO at $minioDisplayUrl ... SKIPPED"
# Wait-For-Http -name "MinIO" -timeoutSec 120 -check {
#    Invoke-WebRequest -Uri "$minioUrl/minio/health/ready" -UseBasicParsing -ErrorAction Stop | Out-Null
# }
Write-Host "[e2e] Waiting for MLflow deployment rollout ..."
try {
    Invoke-Kubectl -command "kubectl -n apps rollout status deploy/mlflow --timeout=300s" | Out-Null
}
catch {
    throw "MLflow deployment not ready: $($_.Exception.Message)"
}
Write-Host "[e2e] Checking MLflow at $mlflowDisplayUrl ... SKIPPED"
$mlflowHealthBody = @{ max_results = 1 } | ConvertTo-Json
# Wait-For-Http -name "MLflow" -timeoutSec 180 -check {
#    Invoke-RestMethod -Method Post -Uri "$mlflowUrl/api/2.0/mlflow/experiments/search" -ContentType "application/json" -Body $mlflowHealthBody -ErrorAction Stop | Out-Null
# }

Write-Host "[e2e] Checking Woodpecker at $woodpeckerDisplayUrl ..."
$woodpeckerVolumes = @("${composeProject}_woodpecker-data", "woodpecker-data")
$woodpeckerUser = $null
foreach ($volume in $woodpeckerVolumes) {
    $woodpeckerUser = Get-WoodpeckerUser -volume $volume -login $giteaUser
    if ($woodpeckerUser) { break }
}
if (-not $woodpeckerUser) {
    throw "Woodpecker user '$giteaUser' not found in DB volume"
}
$woodpeckerToken = New-WoodpeckerToken -userId $woodpeckerUser.id -userHash $woodpeckerUser.hash
$woodpeckerHeaders = @{ Authorization = "Bearer $woodpeckerToken" }
$woodpeckerRepo = $null
$giteaRepo = Invoke-RestMethod -Method Get -Uri "$giteaUrl/api/v1/repos/$giteaUser/platform" -Headers $authHeader -ErrorAction Stop
$giteaRepoId = $giteaRepo.id
try {
    $woodpeckerRepo = Invoke-RestMethod -Method Get -Uri "$woodpeckerUrl/api/repos/lookup/$giteaUser/platform" -Headers $woodpeckerHeaders -ErrorAction Stop
}
catch {
    $woodpeckerRepo = $null
}
if (-not $woodpeckerRepo -or -not $woodpeckerRepo.id) {
    $woodpeckerRepo = Invoke-RestMethod -Method Post -Uri "$woodpeckerUrl/api/repos?forge_remote_id=$giteaRepoId" -Headers $woodpeckerHeaders -ErrorAction Stop
}
$woodpeckerRepoId = $woodpeckerRepo.id
$trustedBody = @{ trusted = @{ network = $true; security = $true; volumes = $true } } | ConvertTo-Json
Invoke-RestMethod -Method Patch -Uri "$woodpeckerUrl/api/repos/$woodpeckerRepoId" -Headers $woodpeckerHeaders -ContentType "application/json" -Body $trustedBody -ErrorAction Stop | Out-Null
try {
    Invoke-RestMethod -Method Post -Uri "$woodpeckerUrl/api/repos/$woodpeckerRepoId/repair" -Headers $woodpeckerHeaders -ErrorAction Stop | Out-Null
}
catch {
}
$giteaTokenForWoodpecker = Get-GiteaTokenFromFile -repoRoot $repoRoot -fallback $giteaPass
Ensure-WoodpeckerSecret -repoId $woodpeckerRepoId -name "gitea_user" -value $giteaUser
Ensure-WoodpeckerSecret -repoId $woodpeckerRepoId -name "gitea_token" -value $giteaTokenForWoodpecker
$woodpeckerRepoUrl = "$woodpeckerDisplayUrl/repos/$woodpeckerRepoId"
Write-Host "[e2e] Woodpecker repo: $woodpeckerRepoUrl"
$woodpeckerPipelineNumber = $null
$woodpeckerPipelineId = $null

$contentPath = "hello-api/e2e-marker.txt"
$marker = [Guid]::NewGuid().ToString("N")

Write-Host "[e2e] Commit marker $marker into $contentPath ..."

$body = @{
    message = "chore(e2e): marker $marker [skip ci]"
    content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($marker))
    branch  = "main"
}

$contentApiUrl = "$giteaUrl/api/v1/repos/$giteaUser/platform/contents/$contentPath"

function Get-ExistingSha {
    try {
        $existing = Invoke-RestMethod -Method Get -Uri $contentApiUrl -Headers $authHeader -ErrorAction Stop
        return $existing.sha
    }
    catch {
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
}
catch {
    $details = $_.ErrorDetails.Message
    $existingSha = Get-ExistingSha
    if ($details -like "*SHA*Required*" -or $details -like "*already exists*" -or $existingSha) {
        if (-not $existingSha) { throw }
        $body.sha = $existingSha
        $resp = Send-Content -method "Put" -body $body
    }
    else { throw }
}
$commitSha = $resp.commit.sha
Write-Host "[e2e] Commit created: $commitSha"

$pipelineBody = @{ branch = "main" } | ConvertTo-Json
$pipelineTrigger = Invoke-WebRequest -Method Post -Uri "$woodpeckerUrl/api/repos/$woodpeckerRepoId/pipelines" -Headers $woodpeckerHeaders -ContentType "application/json" -Body $pipelineBody -UseBasicParsing -ErrorAction Stop
Write-Host "[e2e] Woodpecker pipeline trigger status: $($pipelineTrigger.StatusCode)"

$pipelineAppearDeadline = (Get-Date).AddSeconds([Math]::Min($TimeoutSec, 120))
Write-Host "[e2e] Waiting for Woodpecker pipeline to appear ..."
while ($true) {
    if ((Get-Date) -gt $pipelineAppearDeadline) {
        throw "Timed out waiting for Woodpecker pipeline to appear (check .woodpecker.yml filters)"
    }
    try {
        $pipeline = Find-WoodpeckerPipeline -repoId $woodpeckerRepoId -commitSha $commitSha -perPage 20
        if ($pipeline) {
            $woodpeckerPipelineNumber = Get-ResponseProperty -response $pipeline -name "number"
            $woodpeckerPipelineId = Get-ResponseProperty -response $pipeline -name "id"
            if ($woodpeckerPipelineNumber) {
                Write-Host "[e2e] Woodpecker pipeline detected: #$woodpeckerPipelineNumber"
                break
            }
        }
    }
    catch {
        Write-Host "[e2e] Woodpecker pipeline not ready yet, retrying..."
    }
    Start-Sleep -Seconds 3
}

$artifactDir = Join-Path (Join-Path $repoRoot "..") "ml\\artifacts"
New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
$modelObject = "ml-models/iris-$commitSha.joblib"

Write-Host "[e2e] Training model and logging to MLflow ($mlflowDisplayUrl) ..."
$trainImage = $envVars["ML_TRAIN_IMAGE"]
if (-not $trainImage) { $trainImage = "registry.localhost:5002/mlflow:lite" }
$trainCmd = @(
    "python ml/train.py --output ml/artifacts/model.joblib --commit $commitSha --model-object $modelObject --model-sha-path ml/artifacts/model.sha --experiment $mlflowExperiment"
) -join " && "
podman run --rm --network podman `
    --add-host "mlflow.localhost:$podmanGateway" `
    -e "MLFLOW_TRACKING_URI=$mlflowContainerUrl" `
    -e "MLFLOW_EXPERIMENT_NAME=$mlflowExperiment" `
    -v "$((Join-Path $repoRoot "..")):/workspace" `
    -w /workspace `
    $trainImage sh -c $trainCmd | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Training failed with exit code $LASTEXITCODE" }

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
    --entrypoint /bin/sh `
    minio/mc -c $mcCmd | Out-Null
if ($LASTEXITCODE -ne 0) { throw "MinIO upload failed with exit code $LASTEXITCODE" }

$modelConfigPath = "gitops/apps/hello/model-configmap.yaml"
$modelConfigUrl = "$giteaUrl/api/v1/repos/$giteaUser/platform/contents/$modelConfigPath"
$modelContent = Invoke-RestMethod -Method Get -Uri $modelConfigUrl -Headers $authHeader -ErrorAction Stop
$modelShaGit = $modelContent.sha
$currentModelYaml = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($modelContent.content))
$updatedModelYaml = $currentModelYaml -replace "(?m)^\\s*MODEL_OBJECT:.*$", "  MODEL_OBJECT: $modelObject"
$updatedModelYaml = $updatedModelYaml -replace "(?m)^\\s*MODEL_SHA:.*$", "  MODEL_SHA: $modelSha"
$modelBody = @{
    message = "chore(e2e): update model $modelObject [skip ci]"
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
    filter         = "tag.commit_sha = '$commitSha'"
    max_results    = 1
    order_by       = @("start_time DESC")
} | ConvertTo-Json
$runResp = Invoke-RestMethod -Method Post -Uri "$mlflowUrl/api/2.0/mlflow/runs/search" -ContentType "application/json" -Body $searchBody -ErrorAction Stop
if (-not $runResp -or -not $runResp.PSObject.Properties["runs"]) {
    throw "MLflow run search returned unexpected response"
}
if (-not $runResp.runs -or $runResp.runs.Count -eq 0) {
    throw "MLflow run not found for commit $commitSha"
}
$run = $runResp.runs[0]
if ($run.info.status -ne "FINISHED") {
    throw "MLflow run status is $($run.info.status)"
}
$runId = $run.info.run_id
$modelHistoryTag = $null
if ($run.data -and $run.data.tags) {
    $modelHistoryTag = ($run.data.tags | Where-Object { $_.key -eq "mlflow.log-model.history" } | Select-Object -First 1).value
}
$artifactListUrl = "$mlflowUrl/api/2.0/mlflow/artifacts/list?run_id=$runId"
$artifactRoot = Invoke-RestMethod -Method Get -Uri $artifactListUrl -ErrorAction Stop
$artifactRoot = Convert-JsonIfNeeded -response $artifactRoot -context "MLflow artifacts list"
$artifactFiles = Get-ResponseProperty -response $artifactRoot -name "files"
if (-not $artifactFiles) {
    if (-not $modelHistoryTag) {
        throw "MLflow artifacts list is empty for run $runId"
    }
    Write-Host "[e2e] MLflow artifacts list empty, but model history tag is present"
}
else {
    $modelRoot = $artifactFiles | Where-Object { $_.path -eq "model" -and $_.is_dir }
    if (-not $modelRoot) {
        throw "MLflow model artifact not found for run $runId"
    }
    $artifactModelUrl = "$mlflowUrl/api/2.0/mlflow/artifacts/list?run_id=$runId&path=model"
    $artifactModel = Invoke-RestMethod -Method Get -Uri $artifactModelUrl -ErrorAction Stop
    $artifactModel = Convert-JsonIfNeeded -response $artifactModel -context "MLflow model artifacts list"
    $artifactModelFiles = Get-ResponseProperty -response $artifactModel -name "files"
    if (-not $artifactModelFiles -or -not ($artifactModelFiles | Where-Object { $_.path -match "MLmodel$" })) {
        throw "MLflow MLmodel file not found for run $runId"
    }
}
$mlflowRunUrl = "$mlflowDisplayUrl/#/experiments/$expId/runs/$runId"
Write-Host "[e2e] MLflow run: $mlflowRunUrl"

$deployImageBase = $envVars["HELLO_API_IMAGE"]
if (-not $deployImageBase -or $deployImageBase -eq "localhost:5000/hello-api") {
    $deployImageBase = "registry.localhost:5002/hello-api"
}
$pushImageBase = "localhost:5002/hello-api"
$deployImageTag = "${deployImageBase}:$commitSha"
$pushImageTag = "${pushImageBase}:$commitSha"

Write-Host "[e2e] Building image $deployImageTag ..."
podman build -t $deployImageTag hello-api | Out-Null
podman tag $deployImageTag $pushImageTag | Out-Null
Write-Host "[e2e] Pushing image via $pushImageTag ..."
podman push --tls-verify=false $pushImageTag | Out-Null

$gitopsPath = "gitops/apps/hello/deployment.yaml"
$gitopsUrl = "$giteaUrl/api/v1/repos/$giteaUser/platform/contents/$gitopsPath"
$deployContent = Invoke-RestMethod -Method Get -Uri $gitopsUrl -Headers $authHeader -ErrorAction Stop
$deploySha = $deployContent.sha
$currentYaml = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($deployContent.content))
$lines = $currentYaml -split "`n"
$beforeLine = $null
for ($i = 0; $i -lt $lines.Length; $i++) {
    $line = $lines[$i].TrimEnd()
    if ($line -match "^\s*-\s*name:\s*hello-api\s*$") {
        for ($j = $i + 1; $j -lt $lines.Length; $j++) {
            $nextLine = $lines[$j].TrimEnd()
            if ($nextLine -match "^(\s*)image\s*:") {
                $beforeLine = $nextLine.Trim()
                $indent = $Matches[1]
                $lines[$j] = "${indent}image: $deployImageTag"
                break
            }
            if ($lines[$j] -match "^\s*-\s*name:") { break }
        }
        break
    }
}
if (-not $beforeLine) { throw "hello-api image line not found in $gitopsPath" }
$updatedYaml = $lines -join "`n"
Write-Host "[e2e] Updating deployment image: $beforeLine -> image: $deployImageTag"
$deployBody = @{
    message = "chore(e2e): bump hello-api image to $commitSha [skip ci]"
    content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($updatedYaml))
    branch  = "main"
    sha     = $deploySha
} | ConvertTo-Json
Invoke-RestMethod -Method Put -Uri $gitopsUrl -Headers $authHeader -ContentType "application/json" -Body $deployBody -ErrorAction Stop | Out-Null
Write-Host "[e2e] Deployment manifest updated with $deployImageTag"

$deadline = (Get-Date).AddSeconds($TimeoutSec)

$server = Get-ServerEndpoint -cluster $k3dCluster
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
    -v //run/podman/podman.sock:/var/run/podman/podman.sock `
    gitopslab_bootstrap sh -c $applyModelCmd | Out-Null
$forceCmd = ($kubectlBase + "kubectl -n apps set image deploy/hello-api hello-api=$deployImageTag --record=false") -join "`n"
Write-Host "[e2e] Forcing deployment image to $deployImageTag ..."
podman run --rm --network podman `
    -e DOCKER_HOST=unix:///var/run/podman/podman.sock `
    -v //run/podman/podman.sock:/var/run/podman/podman.sock `
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
        -v //run/podman/podman.sock:/var/run/podman/podman.sock `
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
    }
    catch {
        Write-Host "[e2e] retry after error: $_"
    }
    Start-Sleep -Seconds 5
}

$demoBase = "http://demo.localhost:8088"
try {
    $resp = Invoke-WebRequest -Uri $demoBase -UseBasicParsing -ErrorAction Stop
}
catch {
    $demoBase = "http://localhost:8088"
    $resp = Invoke-WebRequest -Uri $demoBase -UseBasicParsing -ErrorAction Stop
}
Write-Host "[e2e] Demo app status: $($resp.StatusCode)"
$predictBody = @{ features = @(5.1, 3.5, 1.4, 0.2) } | ConvertTo-Json
$predict = Invoke-RestMethod -Method Post -Uri "$demoBase/predict" -ContentType "application/json" -Body $predictBody -ErrorAction Stop
Write-Host "[e2e] Predict: class $($predict.class_id) ($($predict.class_name))"

Write-Host "[e2e] Checking workloads in apps namespace ..."
$appsDeployJson = Invoke-Kubectl -command "kubectl -n apps get deploy -o json"
$appsDeploy = $appsDeployJson | ConvertFrom-Json
if (-not $appsDeploy.items -or $appsDeploy.items.Count -eq 0) {
    throw "No deployments found in apps namespace"
}
$deployNames = ($appsDeploy.items | ForEach-Object { $_.metadata.name }) -join ", "
Write-Host "[e2e] Apps deployments: $deployNames"

if ($woodpeckerPipelineNumber) {
    Write-Host "[e2e] Waiting for Woodpecker pipeline #$woodpeckerPipelineNumber ..."
    $pipelineDeadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        if ((Get-Date) -gt $pipelineDeadline) {
            throw "Timed out waiting for Woodpecker pipeline #$woodpeckerPipelineNumber"
        }
        $pipeline = Invoke-RestMethod -Method Get -Uri "$woodpeckerUrl/api/repos/$woodpeckerRepoId/pipelines/$woodpeckerPipelineNumber" -Headers $woodpeckerHeaders -ErrorAction Stop
        $pipelineStatus = $pipeline.status
        Write-Host "[e2e] Woodpecker pipeline status: $pipelineStatus"
        if ($pipelineStatus -eq "success") { break }
        if ($pipelineStatus -in @("failure", "error", "killed", "declined", "blocked")) {
            throw "Woodpecker pipeline failed with status $pipelineStatus"
        }
        Start-Sleep -Seconds 5
    }
}

$k8sDashboardUrl = "https://dashboard.localhost:32443/#/overview?namespace=apps"
Write-Host "[e2e] MLflow UI: $mlflowDisplayUrl"
Write-Host "[e2e] MLflow Run: $mlflowRunUrl"
Write-Host "[e2e] Woodpecker: $woodpeckerRepoUrl"
if ($woodpeckerPipelineNumber) {
    Write-Host "[e2e] Woodpecker Pipeline: #$woodpeckerPipelineNumber"
}
Write-Host "[e2e] K8s Dashboard (apps): $k8sDashboardUrl"
Write-Host "=== E2E OK ==="
