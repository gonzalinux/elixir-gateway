@echo off
REM Helper script to run ElixirGateway server on Windows
REM Usage: run_server.bat [env_file]
REM Example: run_server.bat .env

set ENV_FILE=%1
if "%ENV_FILE%"=="" set ENV_FILE=.env

REM Load environment variables from file if it exists
if exist %ENV_FILE% (
    echo Loading environment from %ENV_FILE%...
    for /f "usebackq tokens=*" %%a in ("%ENV_FILE%") do (
        REM Skip comments and empty lines
        echo %%a | findstr /r /v "^#" | findstr /r /v "^$" > nul
        if not errorlevel 1 (
            REM Remove inline comments and set variable
            for /f "tokens=1* delims=#" %%b in ("%%a") do set %%b
        )
    )
)

REM Check if clustering is enabled
if "%CLUSTER_ENABLED%"=="true" (
    echo Starting server with clustering enabled...
    elixir --name %NODE_NAME%@%NODE_IP% --erl "-proto_dist inet_tls -ssl_dist_optfile %CD%\priv\ssl_dist.conf -kernel inet_dist_listen_min %CLUSTER_PORT% inet_dist_listen_max %CLUSTER_PORT%" -S mix phx.server
) else (
    echo Starting server...
    elixir -S mix phx.server
)