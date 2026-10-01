FROM python:3.11-slim
RUN pip install --no-cache-dir aiosmtpd==1.4.6
COPY relay.py /app/relay.py
USER 65532:65532
CMD ["python", "/app/relay.py"]
