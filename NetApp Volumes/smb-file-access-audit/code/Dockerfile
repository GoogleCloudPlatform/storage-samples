FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY collector.py /app/collector.py
EXPOSE 8080
CMD ["python3", "-u", "/app/collector.py"]
