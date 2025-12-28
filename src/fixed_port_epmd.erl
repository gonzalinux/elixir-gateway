-module(fixed_port_epmd).
-behaviour(erl_epmd).
-export([start_link/0, register_node/2, register_node/3, port_please/2,
         address_please/3, names/1, listen_port_please/2]).

%% Custom EPMD module for EPMD-less clustering with fixed ports.
%% All nodes use the same port from CLUSTER_PORT environment variable.

-define(DEFAULT_PORT, 9100).

%% Start link - required by behaviour but we don't need a process
start_link() ->
    ignore.

%% Register node - no-op since we don't use EPMD
register_node(_Name, _Port) ->
    {ok, -1}.

register_node(_Name, _Port, _Driver) ->
    {ok, -1}.

%% Port resolution - return the fixed cluster port
port_please(_Name, _Host) ->
    Port = get_cluster_port(),
    {port, Port, 5}.

%% Address resolution - not used
address_please(_Name, _Host, _Family) ->
    {error, nxdomain}.

%% List names - return empty since no EPMD
names(_Hostname) ->
    {ok, []}.

%% Listen port - return the cluster port
listen_port_please(_Name, _Host) ->
    Port = get_cluster_port(),
    {ok, Port}.

%% Private functions
get_cluster_port() ->
    case os:getenv("CLUSTER_PORT") of
        false -> ?DEFAULT_PORT;
        PortStr ->
            case string:to_integer(PortStr) of
                {Port, _} when is_integer(Port) -> Port;
                _ -> ?DEFAULT_PORT
            end
    end.
