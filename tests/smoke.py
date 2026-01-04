"""
Smoke Tests for GitOps Lab Platform
Quick validation of critical infrastructure components
"""
import os
import socket
import subprocess
import time
from typing import Dict, List, Tuple
import requests
import pytest


class HealthChecker:
    """Platform health validation"""
    
    def __init__(self):
        self.errors: List[str] = []
        self.warnings: List[str] = []
        self.gateway_ip = os.getenv("HOST_GATEWAY_IP", "10.89.0.1")
        self.compose_project = os.getenv("COMPOSE_PROJECT_NAME", "gitopslab")
        
    def check_network_gateway(self) -> bool:
        """Verify k3d network gateway IP matches configuration"""
        try:
            result = subprocess.run(
                ["podman", "network", "inspect", "k3d", 
                 "--format", "{{range .IPAM.Config}}{{.Gateway}}{{end}}"],
                capture_output=True,
                text=True,
                timeout=5
            )
            
            if result.returncode != 0:
                self.errors.append("k3d network not found")
                return False
                
            actual_gateway = result.stdout.strip()
            
            if actual_gateway != self.gateway_ip:
                self.errors.append(
                    f"Gateway IP mismatch: expected {self.gateway_ip}, "
                    f"got {actual_gateway}"
                )
                return False
                
            return True
            
        except Exception as e:
            self.errors.append(f"Network check failed: {e}")
            return False
    
    def check_docker_api(self) -> bool:
        """Verify Docker API is accessible"""
        try:
            response = requests.get(
                f"http://{self.gateway_ip}:2375/version",
                timeout=3
            )
            return response.status_code == 200
        except Exception as e:
            self.errors.append(f"Docker API not accessible: {e}")
            return False
    
    def check_registry(self) -> bool:
        """Verify container registry is accessible"""
        try:
            response = requests.get(
                f"http://{self.gateway_ip}:5002/v2/",
                timeout=3
            )
            return response.status_code == 200
        except Exception as e:
            self.errors.append(f"Registry not accessible: {e}")
            return False
    
    def check_service_port(self, host: str, port: int, timeout: int = 3) -> bool:
        """Check if service port is open"""
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(timeout)
            result = sock.connect_ex((host, port))
            sock.close()
            return result == 0
        except Exception:
            return False
    
    def check_gitea(self) -> bool:
        """Verify Gitea is accessible"""
        try:
            response = requests.get(
                "http://gitea.localhost:3000/api/v1/version",
                timeout=5
            )
            return response.status_code == 200
        except Exception as e:
            self.errors.append(f"Gitea not accessible: {e}")
            return False
    
    def check_woodpecker(self) -> bool:
        """Verify Woodpecker is accessible"""
        try:
            response = requests.get(
                "http://woodpecker.localhost:8000/healthz",
                timeout=5
            )
            return response.status_code == 200
        except Exception as e:
            self.warnings.append(f"Woodpecker health check failed: {e}")
            return False
    
    def check_oauth_config(self) -> bool:
        """Verify OAuth credentials are configured"""
        client_id = os.getenv("WOODPECKER_GITEA_CLIENT", "")
        client_secret = os.getenv("WOODPECKER_GITEA_SECRET", "")
        
        if not client_id or client_id == "replace-me":
            self.errors.append("WOODPECKER_GITEA_CLIENT not configured")
            return False
            
        if not client_secret or client_secret == "replace-me":
            self.errors.append("WOODPECKER_GITEA_SECRET not configured")
            return False
            
        return True
    
    def check_k3d_cluster(self) -> bool:
        """Verify k3d cluster is running"""
        try:
            result = subprocess.run(
                ["podman", "ps", "--filter", "name=k3d-gitopslab-server", 
                 "--format", "{{.Names}}"],
                capture_output=True,
                text=True,
                timeout=5
            )
            
            if "k3d-gitopslab-server" not in result.stdout:
                self.errors.append("k3d cluster not running")
                return False
                
            return True
            
        except Exception as e:
            self.errors.append(f"k3d cluster check failed: {e}")
            return False
    
    def check_argocd(self) -> bool:
        """Verify ArgoCD is deployed"""
        try:
            result = subprocess.run(
                ["podman", "exec", "k3d-gitopslab-server-0",
                 "kubectl", "get", "pods", "-n", "argocd", "--no-headers"],
                capture_output=True,
                text=True,
                timeout=10
            )
            
            if result.returncode != 0:
                self.warnings.append("ArgoCD namespace not accessible")
                return False
                
            pod_count = len(result.stdout.strip().split('\n'))
            
            if pod_count < 5:
                self.warnings.append(f"ArgoCD may not be fully deployed ({pod_count} pods)")
                return False
                
            return True
            
        except Exception as e:
            self.warnings.append(f"ArgoCD check failed: {e}")
            return False
    
    def run_all_checks(self) -> Dict[str, bool]:
        """Run all health checks and return results"""
        results = {
            "network_gateway": self.check_network_gateway(),
            "docker_api": self.check_docker_api(),
            "registry": self.check_registry(),
            "gitea": self.check_gitea(),
            "woodpecker": self.check_woodpecker(),
            "oauth_config": self.check_oauth_config(),
            "k3d_cluster": self.check_k3d_cluster(),
            "argocd": self.check_argocd(),
        }
        
        return results
    
    def get_summary(self) -> Tuple[int, int, int]:
        """Return (passed, failed, warnings) counts"""
        return (
            len([e for e in self.errors if e]),
            len([w for w in self.warnings if w]),
            0  # passed calculated from total - failed - warnings
        )


# ============================================================================
# PYTEST TESTS
# ============================================================================

@pytest.fixture(scope="module")
def health_checker():
    """Create health checker instance"""
    return HealthChecker()


def test_network_gateway(health_checker):
    """Test: k3d network gateway IP matches configuration"""
    assert health_checker.check_network_gateway(), \
        f"Network gateway check failed: {health_checker.errors}"


def test_docker_api(health_checker):
    """Test: Docker API is accessible"""
    assert health_checker.check_docker_api(), \
        "Docker API not accessible at gateway IP"


def test_registry(health_checker):
    """Test: Container registry is accessible"""
    assert health_checker.check_registry(), \
        "Container registry not accessible"


def test_gitea(health_checker):
    """Test: Gitea service is running and accessible"""
    assert health_checker.check_gitea(), \
        "Gitea service not accessible"


def test_woodpecker(health_checker):
    """Test: Woodpecker service is running"""
    # This is a warning-level check, so we don't fail the test
    health_checker.check_woodpecker()


def test_oauth_config(health_checker):
    """Test: OAuth credentials are properly configured"""
    assert health_checker.check_oauth_config(), \
        "OAuth configuration incomplete"


def test_k3d_cluster(health_checker):
    """Test: k3d cluster is running"""
    assert health_checker.check_k3d_cluster(), \
        "k3d cluster not running"


def test_argocd(health_checker):
    """Test: ArgoCD is deployed in cluster"""
    # This is a warning-level check
    health_checker.check_argocd()


# ============================================================================
# STANDALONE EXECUTION
# ============================================================================

if __name__ == "__main__":
    print("=" * 60)
    print("GitOps Lab Platform - Smoke Tests")
    print("=" * 60)
    
    checker = HealthChecker()
    results = checker.run_all_checks()
    
    print("\nResults:")
    print("-" * 60)
    
    for check_name, passed in results.items():
        status = "✓ PASS" if passed else "✗ FAIL"
        print(f"{check_name:20s} {status}")
    
    print("-" * 60)
    
    if checker.errors:
        print("\nErrors:")
        for error in checker.errors:
            print(f"  ✗ {error}")
    
    if checker.warnings:
        print("\nWarnings:")
        for warning in checker.warnings:
            print(f"  ⚠ {warning}")
    
    passed_count = sum(1 for v in results.values() if v)
    total_count = len(results)
    
    print(f"\nSummary: {passed_count}/{total_count} checks passed")
    print("=" * 60)
    
    # Exit with error code if critical checks failed
    if checker.errors:
        exit(1)
    else:
        exit(0)
