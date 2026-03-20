FROM elixir:1.19.5-otp-28

ENV DEBIAN_FRONTEND=noninteractive \
    MIX_ENV=dev \
    NPM_VERSION=11.6.2 \
    POETRY_VERSION=1.8.5 \
    CODEX_HOME=/root/.codex \
    PATH=/usr/local/bin:/root/.local/bin:${PATH}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      gh \
      git \
      nodejs \
      npm \
      openssh-client \
      python3 \
      python3-pip \
      python3-venv \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g "npm@${NPM_VERSION}" @openai/codex

RUN python3 -m venv /opt/poetry-venv \
    && /opt/poetry-venv/bin/pip install --upgrade pip \
    && /opt/poetry-venv/bin/pip install "poetry==${POETRY_VERSION}" \
    && ln -s /opt/poetry-venv/bin/poetry /usr/local/bin/poetry

WORKDIR /opt/symphony
COPY . /opt/symphony

RUN mkdir -p "${CODEX_HOME}/skills" \
    && for skill in linear land commit push pull debug; do \
      cp -R "/opt/symphony/.agents/skills/${skill}" "${CODEX_HOME}/skills/${skill}"; \
    done

WORKDIR /opt/symphony/elixir
RUN mix local.hex --force \
    && mix local.rebar --force \
    && mix deps.get \
    && mix build

RUN chmod +x /opt/symphony/elixir/deploy/docker/entrypoint.sh

ENTRYPOINT ["/opt/symphony/elixir/deploy/docker/entrypoint.sh"]
