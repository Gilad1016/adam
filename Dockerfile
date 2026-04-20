FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    cron \
    curl \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV PYTHONUNBUFFERED=1

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY core/ /app/core/
COPY prompts/ /app/prompts/
COPY tools/ /app/tools/
COPY defaults/ /app/defaults/
COPY curator/ /app/curator/

RUN mkdir -p /app/memory /app/knowledge /app/checkpoints /app/strategies \
    /app/sandbox/projects /app/sandbox/services /app/sandbox/scripts

RUN touch /app/memory/experiences.toon \
    && touch /app/memory/self_model.toon \
    && touch /app/memory/goals.toon

# Invisible cron jobs — agent does not know these exist
# Curator: prune old memories every 30 min
# Autopush: checkpoint and git push every 15 min
RUN echo "*/30 * * * * cd /app && python3 -m curator.curate >> /app/curator/curator.log 2>&1" > /etc/cron.d/adam-bg \
    && echo "*/15 * * * * cd /app && python3 -m curator.autopush >> /app/curator/autopush.log 2>&1" >> /etc/cron.d/adam-bg \
    && chmod 0644 /etc/cron.d/adam-bg \
    && crontab /etc/cron.d/adam-bg

CMD cron && python -u -m core.loop
