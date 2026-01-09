"""
Простой скрипт для проверки подключения к MLflow
"""
import sys
import os

# Устанавливаем MLflow tracking URI через переменную окружения
os.environ["MLFLOW_TRACKING_URI"] = "http://10.89.0.1:8090"

try:
    import mlflow
    
    print(f"✓ MLflow tracking URI установлен: {os.environ['MLFLOW_TRACKING_URI']}")
    
    # Пытаемся получить список экспериментов
    from mlflow.tracking import MlflowClient
    client = MlflowClient()
    experiments = client.search_experiments()
    
    print(f"✓ Успешно подключились к MLflow!")
    print(f"✓ Найдено экспериментов: {len(experiments)}")
    
    for exp in experiments:
        print(f"  - {exp.name} (ID: {exp.experiment_id})")
    
    print("\n✅ MLflow подключение работает корректно!")
    sys.exit(0)
    
except Exception as e:
    print(f"❌ Ошибка подключения к MLflow: {e}")
    print(f"   Тип ошибки: {type(e).__name__}")
    import traceback
    traceback.print_exc()
    sys.exit(1)

