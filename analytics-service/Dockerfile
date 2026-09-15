FROM python:3.10.21-slim-bookworm AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
	PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt .
RUN python -m venv /opt/venv \
	&& /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

FROM python:3.10.21-slim-bookworm AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
	PYTHONUNBUFFERED=1 \
	PATH="/opt/venv/bin:${PATH}"

WORKDIR /app

RUN groupadd -g 10001 app && useradd -u 10001 -g app -s /usr/sbin/nologin -m app

COPY --from=builder /opt/venv /opt/venv
COPY . .

RUN chown -R app:app /app

USER 10001:10001

EXPOSE 8005

HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8005/health', timeout=2)" || exit 1

CMD ["gunicorn", "--bind", "0.0.0.0:8005", "app:app"]
