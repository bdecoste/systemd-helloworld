# Containerize the SAME helloworld.py used by the systemd deployment.
# No changes to the app: same env-var config, same stdout logging.
FROM python:3.12-slim

# Non-root user, mirroring the systemd 'helloworld' service account.
RUN useradd --system --uid 10001 --home /opt/helloworld --shell /usr/sbin/nologin helloworld \
 && install -d -o helloworld -g helloworld /opt/helloworld

WORKDIR /opt/helloworld
COPY --chown=helloworld:helloworld app/helloworld.py /opt/helloworld/helloworld.py

USER helloworld

# Container defaults; overridden by K8s env / ConfigMap.
ENV PORT=8080 \
    GREETING="Hello from EKS (container)" \
    ENVIRONMENT=eks-pod \
    PYTHONUNBUFFERED=1

EXPOSE 8080

# PID 1 receives SIGTERM directly -> the app's signal handler runs.
ENTRYPOINT ["python3", "/opt/helloworld/helloworld.py"]
