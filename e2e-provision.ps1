
Write-Host "[M] Starting Manual Ritual of Provisioning..." -ForegroundColor Cyan

# 1. Start Core Services
Write-Host "[M] Phase 1: Starting Gitea & Woodpecker..." -ForegroundColor Cyan
./stop.bat --clean
py -3.12 -m podman_compose up -d gitea woodpecker-server woodpecker-agent

# 2. Wait for Gitea
Write-Host "[M] Waiting for Gitea to awaken..." -ForegroundColor Cyan
do {
    $check = podman exec gitea wget -q -O- http://localhost:3000/api/v1/version 2>$null
    if ($null -eq $check) { Start-Sleep -Seconds 5; Write-Host "." -NoNewline }
} while ($null -eq $check)
Write-Host " Gitea is ALIVE!" -ForegroundColor Green

# 3. Start Bootstrap
Write-Host "[M] Phase 2: Starting Platform Bootstrap..." -ForegroundColor Cyan
py -3.12 -m podman_compose up -d platform-bootstrap

# 4. Wait for Registry (the critical part)
Write-Host "[M] Waiting for k3d-registry to manifest..." -ForegroundColor Cyan
$registry_ready = $false
for ($i = 0; $i -lt 40; $i++) {
    $reg = podman ps --filter "name=k3d-registry.localhost" --format "{{.Names}}"
    if ($reg -eq "k3d-registry.localhost") {
        # Check if it responds to HTTP
        $check = podman exec k3d-registry.localhost wget -q -O- http://localhost:5000/v2/ 2>$null
        if ($null -ne $check) {
            $registry_ready = $true
            break
        }
    }
    Start-Sleep -Seconds 5
    Write-Host "." -NoNewline
}

if (-not $registry_ready) {
    Write-Host " FAILED: Registry did not appear. Exorcism failed." -ForegroundColor Red
    exit 1
}
Write-Host " Registry is READY!" -ForegroundColor Green

# 5. Build and Push MLflow
Write-Host "[M] Phase 3: Building and Pushing MLflow..." -ForegroundColor Cyan
podman build -t mlflow:lite mlflow
$registry_ip = podman inspect k3d-registry.localhost --format "{{.NetworkSettings.Networks.k3d.IPAddress}}"
podman tag mlflow:lite ${registry_ip}:5000/mlflow:lite
podman push ${registry_ip}:5000/mlflow:lite --tls-verify=false

Write-Host "[M] RITUAL COMPLETE. SYSTEM IS READY FOR E2E." -ForegroundColor Green
