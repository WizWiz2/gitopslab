"""
Train a tiny Iris classifier and save a joblib bundle for the demo MLOps flow.

Example:
  python train.py --output ../hello-api/model/model.joblib
"""

import argparse
import hashlib
import os
import pathlib

import joblib
from sklearn import datasets
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import train_test_split


def train(output: pathlib.Path):
    iris = datasets.load_iris()
    X_train, X_test, y_train, y_test = train_test_split(
        iris.data, iris.target, test_size=0.2, random_state=42, stratify=iris.target
    )
    model = LogisticRegression(max_iter=200, random_state=42)
    model.fit(X_train, y_train)
    acc = model.score(X_test, y_test)
    bundle = {"model": model, "target_names": list(iris.target_names), "accuracy": acc}
    output.parent.mkdir(parents=True, exist_ok=True)
    joblib.dump(bundle, output)
    sha = hashlib.sha256(output.read_bytes()).hexdigest()
    print(f"[train] saved model to {output} (acc={acc:.3f}, sha={sha[:12]})")
    return model, acc, sha


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        default=pathlib.Path(__file__).parent.parent / "hello-api" / "model" / "model.joblib",
    )
    parser.add_argument("--commit", default=os.getenv("CI_COMMIT_SHA", "dev"))
    parser.add_argument("--model-object", default=os.getenv("MODEL_OBJECT", "ml-models/iris.joblib"))
    parser.add_argument("--model-sha-path", type=pathlib.Path)
    parser.add_argument("--experiment", default=os.getenv("MLFLOW_EXPERIMENT_NAME", "hello-api-training"))
    parser.add_argument("--tracking-uri", default=os.getenv("MLFLOW_TRACKING_URI", ""))
    args = parser.parse_args()
    model, acc, sha = train(args.output)

    if args.model_sha_path:
        args.model_sha_path.write_text(f"{sha}\n", encoding="utf-8")

    if args.tracking_uri:
        import mlflow
        from urllib.parse import urlparse
        
        # Resolve .localhost domains for Windows compatibility
        def resolve_localhost_url(url):
            parsed = urlparse(url)
            if parsed.hostname and parsed.hostname.endswith('.localhost'):
                new_netloc = f"localhost:{parsed.port}" if parsed.port else "localhost"
                return parsed._replace(netloc=new_netloc).geturl()
            return url
        
        try:
            resolved_uri = resolve_localhost_url(args.tracking_uri)
            mlflow.set_tracking_uri(resolved_uri)
            mlflow.set_experiment(args.experiment)
            with mlflow.start_run() as run:
                mlflow.log_metric("accuracy", acc)
                mlflow.log_param("commit_sha", args.commit)
                mlflow.log_param("model_object", args.model_object)
                mlflow.log_param("model_sha", sha)
                mlflow.set_tag("commit_sha", args.commit)
                mlflow.set_tag("model_object", args.model_object)
                try:
                    import mlflow.sklearn

                    model_name = os.getenv("MLFLOW_MODEL_NAME")
                    if model_name:
                        mlflow.sklearn.log_model(model, artifact_path="model", registered_model_name=model_name)
                    else:
                        mlflow.sklearn.log_model(model, artifact_path="model")
                except Exception as exc:
                    print(f"[train] mlflow model logging skipped: {exc}")
                mlflow.log_artifact(str(args.output))
                print(f"[train] mlflow run {run.info.run_id}")
        except Exception as e:
            print(f"[train] WARNING: MLflow logging failed, but model was saved. Error: {e}")
            # Do NOT fail the script if MLflow fails, as long as the model key artifacts are produced


if __name__ == "__main__":
    main()
