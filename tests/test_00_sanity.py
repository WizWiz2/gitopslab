import pytest
import os
import glob

def test_script_line_endings():
    \"\"\"Verify that all shell scripts and YAMLs have LF line endings (no CRLF).\"\"\"
    patterns = [\"**/*.sh\", \"**/*.yml\", \"**/*.yaml\"]
    bad_files = []
    
    for pattern in patterns:
        for f in glob.glob(pattern, recursive=True):
            if \"node_modules\" in f or \".git\" in f or \"venv\" in f:
                continue
            with open(f, \"rb\") as fd:
                if b\"\\r\\n\" in fd.read():
                    bad_files.append(f)
                    
    assert not bad_files, f\"Files with CRLF detected (will fail in containers): {bad_files}\"

def test_bootstrap_script_exists():
    assert os.path.exists(\"scripts/bootstrap.sh\")

def test_python_version():
    import sys
    assert sys.version_info >= (3, 10), \"Python 3.10+ required\"
