FROM python:3.12.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app/src \
    OTEL_SERVICE_NAME=demo-app \
    OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317 \
    PYROSCOPE_SERVER_ADDRESS=http://pyroscope:4040 \
    DEPLOYMENT_ENVIRONMENT=local \
    DEMO_LISTEN_ADDR=0.0.0.0:8080

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY src ./src

USER nobody
EXPOSE 8080
CMD ["python", "-m", "demo_app"]
