# WebSocket Proxy Architecture in ExGateway

## Overview

ExGateway implements a sophisticated WebSocket proxy that enables transparent proxying of WebSocket connections to backend services while maintaining session integrity and proper connection management. The proxy supports both LiveView applications and general WebSocket services.

## Architecture Components

### 1. WebSocket Upgrade Detection (`WebSocketUpgradePlug`)

The first component in the pipeline detects incoming WebSocket upgrade requests and initiates the proxy connection.

**Location**: `lib/elixirgateway_web/plugs/websocket_upgrade_plug.ex`

**Key Responsibilities**:
- Detects WebSocket upgrade requests by examining HTTP headers
- Maps the request domain to a backend service using the same configuration as HTTP routing
- Transforms request headers to maintain session integrity
- Upgrades the connection to WebSocket using Phoenix's WebSockAdapter

**Detection Logic**:
```elixir
# Checks for WebSocket upgrade headers
Connection: Upgrade
Upgrade: websocket
```

**Domain Routing**:
Uses the same domain-to-service mapping from application configuration:
```elixir
config :elixir_gateway, :gateway,
  services: %{
    "app.example.com" => "http://192.168.1.10:4000",
    "api.example.com" => "https://192.168.1.11:8080"
  }
```

### 2. Connection Handler (`GunWebSocketHandler`)

The actual WebSocket proxy implementation that manages the connection lifecycle and message forwarding.

**Location**: `lib/elixirgateway_web/handlers/gun_websocket_handler.ex`

**Key Features**:
- Implements the `WebSock` behavior for Phoenix compatibility
- Uses Gun HTTP client for high-performance WebSocket connections
- Provides bidirectional message forwarding
- Handles all WebSocket frame types (text, binary, ping, pong)
- Manages connection timeouts and error recovery

## Connection Flow

### 1. Initial Request Detection
```
Client → ExGateway → WebSocketUpgradePlug
                   ↓
              [Detects WebSocket headers]
                   ↓
              [Maps domain to backend service]
```

### 2. Header Transformation
The proxy carefully transforms headers to maintain session validity:

**Preserved Headers**:
- `origin` - Kept unchanged for session validation
- `cookie` - Forwarded for authentication continuity
- `authorization` - For API authentication

**Transformed Headers**:
- `host` - Updated to point to the target service
- Protocol URLs converted from HTTP/HTTPS to WS/WSS

### 3. Connection Establishment
```
ExGateway → Gun Client → Backend Service
    ↓           ↓              ↓
[Upgrade]   [TCP Connect]  [Accept WS]
    ↓           ↓              ↓
[Handler]   [WS Upgrade]   [Ready]
```

### 4. Bidirectional Message Flow
```
Client ←→ ExGateway Handler ←→ Gun Client ←→ Backend Service
        [WebSock interface]     [Gun WS]
```

## Message Handling

### Client to Backend
1. Client sends WebSocket frame to ExGateway
2. `handle_in/2` receives the frame
3. Frame is forwarded to Gun client via `:gun.ws_send/3`
4. Gun client sends frame to backend service

### Backend to Client
1. Backend service sends frame to Gun client
2. Gun client receives `:gun_ws` message
3. `handle_info/2` processes the message
4. Frame is replied back to client via `{:reply, :ok, frame, state}`

## Supported Frame Types

- **Text frames**: Standard text messages
- **Binary frames**: Binary data transmission
- **Ping frames**: Connection health checks
- **Pong frames**: Ping responses
- **Close frames**: Connection termination

## Error Handling & Recovery

### Connection Timeouts
- 10-second timeout for WebSocket upgrade
- Connection establishment timeout via Gun
- Automatic cleanup on timeout

### Error Scenarios
- **Service unavailable**: Returns 404 for unmapped domains
- **Connection failures**: Logs errors and terminates gracefully
- **Upgrade failures**: Handles HTTP error responses from backend
- **Network issues**: Gun connection monitoring and cleanup

### Logging
Comprehensive logging at different levels:
- Info: Connection establishment and termination
- Debug: Message forwarding and header transformations
- Warning: Timeout and recovery scenarios
- Error: Connection failures and unexpected conditions

## Session Management

### Authentication Preservation
The proxy maintains session integrity through careful header management:

```elixir
# Original origin preserved for session validation
{"origin", original_origin || "http://#{original_host}"}

# Host header points to target service  
{"host", target_host_port}

# Cookies forwarded unchanged
{"cookie", cookie_header}
```

### URL Transformation
HTTP/HTTPS service URLs are automatically converted to WebSocket URLs:
```elixir
# Example transformation
"https://api.example.com" → "wss://api.example.com/path?query"
"http://localhost:4000" → "ws://localhost:4000/path?query"
```

## Integration with Phoenix Pipeline

The WebSocket proxy integrates seamlessly with the existing gateway pipeline:

```elixir
pipeline :gateway do
  plug ElixirGatewayWeb.Plugs.RateLimiter        # Rate limiting applied
  plug ElixirGatewayWeb.Plugs.WebSocketUpgradePlug # WebSocket detection
  plug ElixirGatewayWeb.Plugs.DomainRouter        # HTTP fallback
  plug ElixirGatewayWeb.Plugs.RequestForwarder    # HTTP forwarding
end
```

WebSocket connections pass through rate limiting but bypass HTTP-specific plugs once upgraded.

## LiveView Support

While not explicitly LiveView-specific, this proxy architecture fully supports Phoenix LiveView applications:

- **Session continuity**: Maintains Phoenix sessions through cookie forwarding
- **Origin validation**: Preserves origin headers for CSRF protection  
- **Real-time updates**: Handles all LiveView WebSocket communication
- **Error handling**: Graceful degradation when LiveView processes crash

## Performance Characteristics

- **Gun HTTP client**: High-performance, low-latency WebSocket connections
- **Connection pooling**: Gun manages connection pools to backend services
- **Memory efficiency**: Minimal state management per connection
- **Concurrent connections**: Supports thousands of simultaneous WebSocket connections

## Configuration

WebSocket proxying uses the same configuration as HTTP proxying - no additional setup required:

```elixir
config :elixir_gateway, :gateway,
  services: %{
    "liveview-app.com" => "http://localhost:4000",
    "websocket-api.com" => "https://internal.api:8080"
  }
```

The proxy automatically handles both HTTP requests and WebSocket upgrades for configured domains.