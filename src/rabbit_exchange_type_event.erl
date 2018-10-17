%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2018 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_exchange_type_event).
-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/rabbit_framing.hrl").

-export([register/0, unregister/0]).
-export([init/1, handle_call/2, handle_event/2, handle_info/2,
         terminate/2, code_change/3]).
-export([info/1, info/2]).

-export([fmt_proplist/1]). %% testing

-define(EXCH_NAME, <<"amq.rabbitmq.event">>).

-record(state, {vhost}).

-rabbit_boot_step({rabbit_event_exchange,
                   [{description, "event exchange"},
                    {mfa,         {?MODULE, register, []}},
                    {cleanup,     {?MODULE, unregister, []}},
                    {requires,    recovery},
                    {enables,     routing_ready}]}).

%%----------------------------------------------------------------------------

info(_X) -> [].

info(_X, _) -> [].

register() ->
    rabbit_exchange:declare(exchange(), topic, true, false, true, [],
                            ?INTERNAL_USER),
    gen_event:add_handler(rabbit_event, ?MODULE, []).

unregister() ->
    rabbit_exchange:delete(exchange(), false, ?INTERNAL_USER),
    gen_event:delete_handler(rabbit_event, ?MODULE, []).

exchange() ->
    exchange(get_vhost()).

exchange(VHost) ->
    _ = ensure_vhost_exists(VHost),
    rabbit_misc:r(VHost, exchange, ?EXCH_NAME).

%%----------------------------------------------------------------------------

init([]) ->
    VHost = get_vhost(),
    {ok, #state{vhost = VHost}}.

handle_call(_Request, State) -> {ok, not_understood, State}.

handle_event(#event{type      = Type,
                    props     = Props,
                    timestamp = TS,
                    reference = none}, #state{vhost = VHost} = State) ->
    case key(Type) of
        ignore -> ok;
        Key    ->
                  Props2 = [{<<"timestamp_in_ms">>, TS} | Props],
                  PBasic = #'P_basic'{delivery_mode = 2,
                                      headers = fmt_proplist(Props2),
                                      %% 0-9-1 says the timestamp is a
                                      %% "64 bit POSIX
                                      %% timestamp". That's second
                                      %% resolution, not millisecond.
                                      timestamp = erlang:convert_time_unit(
                                                    TS, milli_seconds, seconds)},
            Msg = rabbit_basic:message(exchange(VHost), Key, PBasic, <<>>),
                  rabbit_basic:publish(
                    rabbit_basic:delivery(false, false, Msg, undefined))
    end,
    {ok, State};
handle_event(_Event, State) ->
    {ok, State}.

handle_info(_Info, State) -> {ok, State}.

terminate(_Arg, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%----------------------------------------------------------------------------

ensure_vhost_exists(VHost) ->
    case rabbit_vhost:exists(VHost) of
        false -> rabbit_vhost:add(VHost, ?INTERNAL_USER);
        _     -> ok
    end.

%% pattern matching is way more efficient that the string operations,
%% let's use all the keys we're aware of to speed up the handler.
%% Any unknown or new one will be processed as before (see last function clause).
key(queue_deleted) ->
    <<"queue.deleted">>;
key(queue_created) ->
    <<"queue.created">>;
key(exchange_created) ->
    <<"exchange.created">>;
key(exchange_deleted) ->
    <<"exchange.deleted">>;
key(binding_created) ->
    <<"binding.created">>;
key(connection_created) ->
    <<"connection.created">>;
key(connection_closed) ->
    <<"connection.closed">>;
key(channel_created) ->
    <<"channel.created">>;
key(channel_closed) ->
    <<"channel.closed">>;
key(consumer_created) ->
    <<"consumer.created">>;
key(consumer_deleted) ->
    <<"consumer.deleted">>;
key(queue_stats) ->
    ignore;
key(connection_stats) ->
    ignore;
key(policy_set) ->
    <<"policy.set">>;
key(policy_cleared) ->
    <<"policy.cleared">>;
key(parameter_set) ->
    <<"parameter.set">>;
key(parameter_cleared) ->
    <<"parameter.cleared">>;
key(vhost_created) ->
    <<"vhost.created">>;
key(vhost_deleted) ->
    <<"vhost.deleted">>;
key(vhost_limits_set) ->
    <<"vhost.limits.set">>;
key(vhost_limits_cleared) ->
    <<"vhost.limits.cleared">>;
key(user_authentication_success) ->
    <<"user.authentication.success">>;
key(user_authentication_failure) ->
    <<"user.authentication.failure">>;
key(user_created) ->
    <<"user.created">>;
key(user_deleted) ->
    <<"user.deleted">>;
key(user_password_changed) ->
    <<"user.password.changed">>;
key(user_password_cleared) ->
    <<"user.password.cleared">>;
key(user_tags_set) ->
    <<"user.tags.set">>;
key(permission_created) ->
    <<"permission.created">>;
key(permission_deleted) ->
    <<"permission.deleted">>;
key(topic_permission_created) ->
    <<"topic.permission.created">>;
key(topic_permission_deleted) ->
    <<"topic.permission.deleted">>;
key(alarm_set) ->
    <<"alarm.set">>;
key(alarm_cleared) ->
    <<"alarm.cleared">>;
key(shovel_worker_status) ->
    <<"shovel.worker.status">>;
key(shovel_worker_removed) ->
    <<"shovel.worker.removed">>;
key(federation_link_status) ->
    <<"federation.link.status">>;
key(federation_link_removed) ->
    <<"federation.link.removed">>;
key(S) ->
    case string:tokens(atom_to_list(S), "_") of
        [_, "stats"] -> ignore;
        Tokens       -> list_to_binary(string:join(Tokens, "."))
    end.

fmt_proplist(Props) ->
    lists:foldl(fun({K, V}, Acc) ->
                        case fmt(a2b(K), V) of
                            L when is_list(L) -> lists:append(L, Acc);
                            T -> [T | Acc]
                        end
                end, [], Props).

fmt(K, #resource{virtual_host = VHost, 
                 name         = Name}) -> [{K,           longstr, Name},
                                           {<<"vhost">>, longstr, VHost}];
fmt(K, V) -> {T, Enc} = fmt(V),
             {K, T, Enc}.

fmt(true)                 -> {bool, true};
fmt(false)                -> {bool, false};
fmt(V) when is_atom(V)    -> {longstr, atom_to_binary(V, utf8)};
fmt(V) when is_integer(V) -> {long, V};
fmt(V) when is_number(V)  -> {float, V};
fmt(V) when is_binary(V)  -> {longstr, V};
fmt([{_, _}|_] = Vs)      -> {table, fmt_proplist(Vs)};
fmt(Vs) when is_list(Vs)  -> {array, [fmt(V) || V <- Vs]};
fmt(V) when is_pid(V)     -> {longstr,
                              list_to_binary(rabbit_misc:pid_to_string(V))};
fmt(V)                    -> {longstr,
                              list_to_binary(
                                rabbit_misc:format("~1000000000p", [V]))}.

a2b(A) when is_atom(A)   -> atom_to_binary(A, utf8);
a2b(B) when is_binary(B) -> B.

get_vhost() ->
    case application:get_env(rabbitmq_event_exchange, vhost) of
        undefined ->
            {ok, V} = application:get_env(rabbit, default_vhost),
            V;
        {ok, V} ->
            V
    end.
