FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt && useradd --create-home --uid 10001 farmer
COPY . /app
ENV FARMER_PACK_DIR=/app/resources/packs FARMER_DATA_DIR=/app/data PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN chmod -R a+rX /app && mkdir /app/data && chown farmer:farmer /app/data
USER farmer
EXPOSE 8088
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8088", "--no-access-log"]
