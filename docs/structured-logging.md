# Structured Logging with Grafana Alloy → VictoriaLogs

Dual-output logging: stdout keeps its human-readable format, JSON lines go to a file for Alloy to ingest.

## How it works

```
App → stdout (plain text, unchanged)
    → /app/logs/app.json.log (JSON lines, one per event)
         → Alloy (tails file, extracts labels + structured metadata)
              → VictoriaLogs
```

## Elixir side

**1. JSON formatter** (`lib/your_app/json_log_handler.ex`)

Copy `lib/elixir_gateway/json_log_handler.ex`. Change `@handler_id` to something unique for your app.

Key points:
- Uses `:logger_std_h` (Erlang's built-in handler) — avoids file process-linking issues
- Formatter produces flat JSON: all metadata fields at top level alongside `message`, `level`, `node`, `timestamp`
- Runs as a second OTP logger handler; the `:console` handler is untouched

**2. Start it in `application.ex`**

```elixir
case Application.get_env(:your_app, :json_logging) do
  [enabled: true, path: path] -> YourApp.JsonLogHandler.attach(path)
  _ -> :ok
end
```

**3. Config**

`config/config.exs`:
```elixir
config :your_app, :json_logging, enabled: false, path: "/app/logs/app.json.log"
```

`config/runtime.exs`:
```elixir
if path = System.get_env("JSON_LOG_PATH") do
  config :your_app, :json_logging, enabled: true, path: path
end
```

**4. Dockerfile** — create the log directory owned by the app user before the volume is mounted:
```dockerfile
RUN mkdir -p /app/logs && chown -R youruser:youruser /app
```

## Docker Compose side

```yaml
services:
  app:
    environment:
      - JSON_LOG_PATH=/app/logs/app.json.log
    volumes:
      - logs:/app/logs

  alloy:
    image: grafana/alloy:v1.15.0
    volumes:
      - ./alloy/config.alloy:/etc/alloy/config.alloy:ro
      - logs:/app/logs:ro
    command: run /etc/alloy/config.alloy
    environment:
      - LOG_AGGREGATOR_URL=${LOG_AGGREGATOR_URL}
      - DEPLOY_ENV=${DEPLOY_ENV}

volumes:
  logs:
```

`.env`:
```
LOG_AGGREGATOR_URL=http://your-victorialogs:9428/insert/loki/api/v1/push
DEPLOY_ENV=home
```

## Alloy config (`alloy/config.alloy`)

```alloy
local.file_match "app" {
  path_targets = [{"__path__" = "/app/logs/app.json.log"}]
}

loki.source.file "app" {
  targets    = local.file_match.app.targets
  forward_to = [loki.process.app.receiver]
}

loki.process "app" {
  stage.json {
    expressions = {
      level      = "level",
      node       = "node",
      timestamp  = "timestamp",
      message    = "message",
      request_id = "request_id",
      line       = "line",
      pid        = "pid",
    }
  }

  stage.labels {
    values = {
      level = null,
      node  = null,
    }
  }

  stage.static_labels {
    values = {
      app    = "your-app-name",
      deploy = coalesce(env("DEPLOY_ENV"), "unknown"),
    }
  }

  stage.structured_metadata {
    values = {
      request_id = "",
      line       = "",
      pid        = "",
    }
  }

  stage.timestamp {
    source = "timestamp"
    format = "RFC3339"
  }

  stage.output {
    source = "message"
  }

  forward_to = [loki.write.aggregator.receiver]
}

loki.write "aggregator" {
  endpoint {
    url = coalesce(env("LOG_AGGREGATOR_URL"), "")
  }
}
```

## Querying in VictoriaLogs

```
# All logs from the app
{app="your-app-name"}

# Filter by deployment
{app="your-app-name", deploy="home"}

# Filter by level
{app="your-app-name", level="error"}

# Filter by request_id (structured metadata)
{app="your-app-name"} | request_id:"abc123"
```

## Notes

- VictoriaLogs must be >= v0.41.0 for structured metadata support (tested on v1.48.0)
- `request_id` requires `Plug.RequestId` in your Phoenix endpoint pipeline
- The log volume must be initialized with correct permissions — handle this in the Dockerfile, not the entrypoint
