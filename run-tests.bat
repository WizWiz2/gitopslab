@echo off
pip install -r tests/requirements.txt
pytest tests/test_e2e_suite.py
pause
