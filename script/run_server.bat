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
mix deps.get
mid compile

REM Check if clustering is enabled
if "%CLUSTER_ENABLED%"=="true" (
    echo Starting server with clustering enabled...

    REM Auto-detect NODE_IP if not set
    if not defined NODE_IP (
        echo NODE_IP not set, attempting auto-detection...

        REM Use the Mix task to detect IP
        for /f %%i in ('mix elixir_gateway.detect_ip 2^>nul') do set NODE_IP=%%i

        REM If still no IP, fail with helpful message
        if not defined NODE_IP (
            echo ERROR: Could not auto-detect NODE_IP.
            echo Please set NODE_IP explicitly in your %ENV_FILE%:
            echo   NODE_IP=your.server.ip.address
            exit /b 1
        )

        echo Auto-detected NODE_IP: %NODE_IP%
    )

    elixir --name %NODE_NAME%@%NODE_IP% --erl "-proto_dist inet_tls -ssl_dist_optfile %CD%\priv\ssl_dist.conf -kernel inet_dist_listen_min %CLUSTER_PORT% inet_dist_listen_max %CLUSTER_PORT%" -S mix phx.server
) else (
    echo Starting server...
    elixir -S mix phx.server
)
