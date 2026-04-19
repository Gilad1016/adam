FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    cron \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY core/ /app/core/
COPY prompts/ /app/prompts/
COPY tools/ /app/tools/
COPY defaults/ /app/defaults/
COPY curator/ /app/curator/

RUN mkdir -p /app/memory /app/knowledge /app/checkpoints /app/strategies

RUN touch /app/memory/experiences.toon \
    && touch /app/memory/self_model.toon \
    && touch /app/memory/goals.toon

# Curator cron — runs every 30 min, invisible to agent
RUN echo "*/30 * * * * cd /app && python -m curator.curate >> /app/curator/curator.log 2>&1" > /etc/cron.d/curator \
    && chmod 0644 /etc/cron.d/curator \
    && crontab /etc/cron.d/curator

CMD cron && python -m core.loop
