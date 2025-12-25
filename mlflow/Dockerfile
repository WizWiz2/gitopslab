FROM python:3.10-slim

WORKDIR /mlflow

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

EXPOSE 5000

CMD ["mlflow", "server", "--backend-store-uri", "sqlite:////mlflow/mlflow.db", "--default-artifact-root", "mlflow-artifacts:/", "--artifacts-destination", "/mlflow/artifacts", "--serve-artifacts", "--host", "0.0.0.0", "--port", "5000"]
