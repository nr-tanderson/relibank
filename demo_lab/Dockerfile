FROM python:3.12-slim
WORKDIR /app
COPY demo_lab/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY bill_pay/payment_lab.py bill_pay/payment_lab_api.py /app/bill_pay/
COPY demo_lab/gateway.py /app/demo_lab/gateway.py
ENV NEW_RELIC_ENABLED=false
ENV NEW_RELIC_DISTRIBUTED_TRACING_ENABLED=true
USER 10001:10001
EXPOSE 8080
CMD ["uvicorn", "bill_pay.payment_lab_api:app", "--host", "0.0.0.0", "--port", "8080"]