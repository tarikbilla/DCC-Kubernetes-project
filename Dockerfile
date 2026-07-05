# ---------------------------------------------------------------------------
# DCC Kubernetes Demo — container image
#
# Build:  docker build -t dcc-web:1.0.0 --build-arg APP_VERSION=1.0.0 .
# Run:    docker run --rm -p 8000:8000 dcc-web:1.0.0
# ---------------------------------------------------------------------------

# Small official Python base image (~50 MB) — never use full OS images for
# production containers; smaller image = faster pulls = faster pod startup.
FROM python:3.12-slim

# Bake the app version into the image at build time. Building the same code
# with a different APP_VERSION produces the distinct image tags we use to
# demonstrate a Kubernetes rolling update (1.0.0 -> 2.0.0).
ARG APP_VERSION=1.0.0
ENV APP_VERSION=${APP_VERSION} \
    # Log straight to stdout — containers must log to stdout/stderr so
    # `docker logs` / `kubectl logs` can read them.
    PYTHONUNBUFFERED=1 \
    # Don't write .pyc files inside the container.
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# Copy and install dependencies FIRST, code afterwards: Docker caches each
# layer, so editing app code does not re-run pip install on rebuilds.
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ .

# Never run containers as root — if the app is compromised, the attacker
# is an unprivileged user, not root.
RUN useradd --create-home appuser
USER appuser

# Documentation of the port the app listens on (the actual publishing
# happens with `docker run -p` or a Kubernetes Service).
EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
