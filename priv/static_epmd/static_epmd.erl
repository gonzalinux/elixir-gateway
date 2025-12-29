-module(static_epmd).
-behaviour(gen_server).

%% This module implements a static EPMD (Erlang Port Mapper Daemon) replacement
%% that extracts port numbers from node names (e.g., node_9100 -> port 9100).
%%
%% Based on epmdless_static from https://github.com/tsloughter/epmdless
%% with added support for dynamic port detection from node names.
%%
%% To use this module, compile it and pass it to the Erlang VM:
%% -epmd_module static_epmd

%% API
-export([start_link/0,
         register_node/3,
         port_please/2,
         address_please/3,
         listen_port_please/2,
         names/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-ifdef(OTP_RELEASE).
-if(?OTP_RELEASE >= 23).
-define(ERL_DIST_VER, 6).
-else.
-define(ERL_DIST_VER, 5).
-endif.
-else.
-define(ERL_DIST_VER, 5).
-endif.

-record(state, {port :: inet:port_number()}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Called when registering the local node
register_node(_Name, _Port, _Driver) ->
    %% Return a random creation number (required by protocol)
    {ok, rand:uniform(3)}.

%% Called to find the port for a remote node
%% This is where we extract the port from the node name
port_please(Name, _Ip) when is_list(Name) ->
    io:format("[StaticEpmd] port_please called for: ~s~n", [Name]),

    %% Try to extract port from node name (e.g., "node_9100" -> 9100)
    case extract_port_from_name(Name) of
        {ok, Port} ->
            io:format("[StaticEpmd] Extracted port ~p from name ~s~n", [Port, Name]),
            {port, Port, ?ERL_DIST_VER};
        error ->
            %% If we can't extract port from name, fall back to configured port
            io:format("[StaticEpmd] Could not extract port from name ~s, using default~n", [Name]),
            case gen_server:call(?MODULE, port_please, infinity) of
                {ok, Port} ->
                    {port, Port, ?ERL_DIST_VER};
                error ->
                    noport
            end
    end.

%% Called to resolve hostname to IP address
address_please(Name, Host, AddressFamily) ->
    io:format("[StaticEpmd] address_please called for: ~s@~s~n", [Name, Host]),

    %% First resolve the host to an IP
    case inet:getaddr(Host, AddressFamily) of
        {ok, Ip} ->
            %% Then get the port
            case port_please(Name, Ip) of
                {port, Port, Version} ->
                    {ok, Ip, Port, Version};
                noport ->
                    {error, nxdomain}
            end;
        {error, _} = Error ->
            Error
    end.

%% Called to get the local listening port
listen_port_please(_Name, _Host) ->
    case gen_server:call(?MODULE, port_please, infinity) of
        {ok, Port} ->
            {ok, Port};
        error ->
            {error, no_port_configured}
    end.

%% Called to list registered names (used by net_adm:names())
names(_Hostname) ->
    %% We don't maintain a registry, so return error
    {error, address}.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    %% Get the port from environment variable or command-line args
    Port = case os:getenv("ERL_DIST_PORT") of
        false ->
            %% Try command-line args (e.g., -erl_epmd_port 9100)
            case init:get_argument(erl_epmd_port) of
                {ok, [[PortStr]]} ->
                    list_to_integer(PortStr);
                _ ->
                    %% Default fallback
                    io:format("[StaticEpmd] WARNING: No ERL_DIST_PORT env var or -erl_epmd_port arg found~n"),
                    0
            end;
        PortStr when is_list(PortStr) ->
            list_to_integer(PortStr);
        PortStr ->
            binary_to_integer(list_to_binary(PortStr))
    end,

    io:format("[StaticEpmd] Initialized with local port: ~p~n", [Port]),
    {ok, #state{port = Port}}.

handle_call(port_please, _From, #state{port = 0} = State) ->
    %% No port configured
    {reply, error, State};
handle_call(port_please, _From, #state{port = Port} = State) ->
    {reply, {ok, Port}, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal functions
%%====================================================================

%% Extract port number from node name
%% Node names are expected to be in format: name_PORT (e.g., "gateway_9100")
%% The port is always the last part after the last underscore
extract_port_from_name(Name) when is_list(Name) ->
    %% Split by underscore (95 is ASCII for '_')
    Parts = string:split(Name, "_", all),

    case Parts of
        [] ->
            error;
        PartsList ->
            %% Get the last part
            LastPart = lists:last(PartsList),

            %% Try to convert to integer
            try
                Port = list_to_integer(LastPart),
                %% Validate port range
                if
                    Port > 0 andalso Port =< 65535 ->
                        {ok, Port};
                    true ->
                        error
                end
            catch
                error:badarg ->
                    error
            end
    end;
extract_port_from_name(_) ->
    error.
