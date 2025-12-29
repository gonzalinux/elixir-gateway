# ElixirGateway - Production Dockerfile
# Multi-stage build for creating a minimal production image

# Build stage
FROM hexpm/elixir:1.15.7-erlang-26.1.2-alpine-3.18.4 AS builder

# Set environment variables for build
ENV MIX_ENV=prod
ENV SECRET_KEY_BASE="dummy-secret-for-compilation"

# Install build dependencies
RUN apk add --no-cache \
    build-base \
    git \
    curl \
    tar \
    gzip

# Create app directory
WORKDIR /app

# Copy mix configuration
COPY mix.exs mix.lock ./

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Install dependencies
RUN mix deps.get --only prod && \
    mix deps.compile

# Copy application code
COPY lib lib
COPY config config
COPY priv priv

# Compile the application
RUN mix compile

# Create release
RUN mix release

# Runtime stage
FROM alpine:3.18.4

# Install runtime dependencies
RUN apk add --no-cache \
    openssl \
    ncurses-libs \
    ca-certificates \
    bash \
    libstdc++ \
    libgcc

# Create non-root user
RUN addgroup -g 1000 gateway && \
    adduser -u 1000 -G gateway -s /bin/sh -D gateway

# Create directories
RUN mkdir -p /app && \
    mkdir -p /etc/elixirgateway/certs && \
    chown -R gateway:gateway /app && \
    chown -R gateway:gateway /etc/elixirgateway

# Copy the release from builder stage
COPY --from=builder --chown=gateway:gateway /app/_build/prod/rel/elixirgateway /app

# Set working directory
WORKDIR /app

# Switch to non-root user
USER gateway

# Set environment variables
ENV HOME=/app
ENV MIX_ENV=prod
ENV HTTP_PORT=4000
ENV HTTPS_PORT=4001

# Expose ports
EXPOSE 4000 4001 4002

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:4000/health || exit 1

# Start the application
CMD ["./bin/elixirgateway", "start"]
