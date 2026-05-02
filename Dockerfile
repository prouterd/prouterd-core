# prouterd daemon — single-process container
# Two-stage build: builder installs gems with native extensions; runtime
# image is slim and only carries the runtime libs needed.
#
#   docker build -t prouterd:latest .
#   docker run -p 8080:8080 -v prouterd-data:/data prouterd:latest
#
# To allow `type docker` blocks (which spawn child containers on the host),
# mount the host Docker socket:
#   -v /var/run/docker.sock:/var/run/docker.sock
# Pure-shell pipelines don't need it.
FROM ruby:3.2-slim-bookworm AS builder

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      build-essential \
      libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy only what bundler needs first so the gem layer caches across
# code changes.
COPY Gemfile Gemfile.lock prouterd.gemspec ./
COPY lib/prouterd/version.rb lib/prouterd/version.rb

RUN bundle config set --local without 'development' \
 && bundle config set --local path '/usr/local/bundle' \
 && bundle install --jobs "$(nproc)"

# Copy source AFTER bundle install so source-only edits don't bust the
# gem cache.
COPY lib lib
COPY exe exe

# ---- runtime stage ----
FROM ruby:3.2-slim-bookworm

# Runtime libs only — no build toolchain.
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      libsqlite3-0 \
      ca-certificates \
      tzdata \
    && rm -rf /var/lib/apt/lists/*

# Non-root user. Daemon doesn't need root for anything we do today.
RUN groupadd --system --gid 1000 prouterd \
 && useradd --system --uid 1000 --gid prouterd --no-create-home --shell /usr/sbin/nologin prouterd

WORKDIR /app

COPY --from=builder /app /app
COPY --from=builder /usr/local/bundle /usr/local/bundle

# Persistent state lives in /data — DB + artifacts + var/prouterd.db.
# Mount as a Docker volume to survive container restarts.
RUN mkdir -p /data && chown prouterd:prouterd /data
ENV PROUTERD_DB=/data/prouterd.db
ENV BUNDLE_PATH=/usr/local/bundle
ENV BUNDLE_GEMFILE=/app/Gemfile

USER prouterd

EXPOSE 8080
VOLUME ["/data"]

# Default: HTTP daemon. Override CMD for one-shot invocations:
#   docker run --rm -v ... prouterd:latest exec "show running-config"
ENTRYPOINT ["bundle", "exec", "ruby", "exe/prouter"]
CMD ["serve", "--bind", "0.0.0.0", "--port", "8080", "--db", "/data/prouterd.db"]
