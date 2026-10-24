%%% Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.
%%%
%%% This source code is licensed under the Apache 2.0 license found in
%%% the LICENSE file in the root directory of this source tree.

-module(wa_raft_server_async_append_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("wa_raft/include/wa_raft.hrl").

-define(APP, wa_raft_async_append_test).
-define(TABLE, wa_raft_async_append_test).
-define(PARTITION, 1).

%% A configuration entry is appended directly after the log's last entry,
%% where an async append in flight is writing, so the leader waits for that
%% append to complete before appending the change.
config_change_waits_for_the_async_append_in_flight_test_() ->
    {timeout, 30, fun () ->
        with_partition(fun (Server, Acceptor) ->
            Last = log_last(Server),
            wa_raft_log_gate:set_owner(self()),
            commit_async(Acceptor, a),
            Appender = await_gate_append(),
            Parent = self(),
            Peer = {Server, 'wa_raft_async_append_peer@nohost'},
            spawn(fun () -> Parent ! {adjusted, wa_raft_server:adjust_membership(Server, add, Peer)} end),
            ?assertEqual(none, maybe_gate_append(200)),
            Appender ! {gate, ok},
            ConfigAppender = await_gate_append(),
            ConfigAppender ! {gate, ok},
            ConfigIndex = Last + 2,
            ?assertMatch({ok, #raft_log_pos{index = ConfigIndex}},
                         receive {adjusted, Adjusted} -> Adjusted after 5000 -> timeout end),
            %% The write committed under the configuration it was written under.
            ?assertEqual(ok, await_commit(a, 1000)),
            ?assertMatch({ok, {_, {_, {write, ?TABLE, a, a}}}}, wa_raft_log_ets_get(Last + 1)),
            ?assertMatch({ok, {_, {_, {config, _}}}}, wa_raft_log_ets_get(ConfigIndex))
        end)
    end}.

%% An append still running after the wait leaves the configuration unchanged
%% and completes as usual afterwards.
config_change_fails_while_the_async_append_runs_on_test_() ->
    {timeout, 30, fun () ->
        with_partition(fun (Server, Acceptor) ->
            Last = log_last(Server),
            Config = wa_raft_server:get_current_config(Server),
            wa_raft_log_gate:set_owner(self()),
            commit_async(Acceptor, a),
            Appender = await_gate_append(),
            Peer = {Server, 'wa_raft_async_append_peer@nohost'},
            ?assertEqual({error, async_append_in_flight}, wa_raft_server:adjust_membership(Server, add, Peer)),
            ?assertEqual(none, maybe_gate_append(0)),
            Appender ! {gate, ok},
            ?assertEqual(ok, await_commit(a, 1000)),
            ?assertEqual(Last + 1, log_last(Server)),
            ?assertEqual(Config, wa_raft_server:get_current_config(Server))
        end)
    end}.

%% A server that crashes rolling back a failed append is restarted right away:
%% shutting down must not wait for the append's worker, which has already
%% finished.
server_restarts_promptly_after_a_failed_rollback_test_() ->
    {timeout, 30, fun () ->
        with_partition(fun (Server, Acceptor) ->
            Before = whereis(Server),
            wa_raft_log_gate:set_owner(self()),
            wa_raft_log_gate:fail_truncate(injected_truncate),
            commit_async(Acceptor, a),
            Appender = await_gate_append(),
            Monitor = erlang:monitor(process, Before),
            Appender ! {gate, {error, injected_append}},
            receive {'DOWN', Monitor, process, Before, _} -> ok after 5000 -> error(server_kept_running) end,
            wa_raft_log_gate:clear(),
            ?assertEqual(ok, await_restart(Server, Before, 2000))
        end)
    end}.

%%------------------------------------------------------------------------------
%% Helpers
%%------------------------------------------------------------------------------

with_partition(Fun) ->
    Dir = tmp_dir(),
    Env = [
        {raft_database, Dir},
        {raft_async_log_append, true},
        {raft_commit_batch_interval_ms, 0}
    ],
    [ok = application:set_env(?APP, Key, Value) || {Key, Value} <- Env],
    {ok, _} = application:ensure_all_started(wa_raft),
    {ok, Sup} = wa_raft_sup:start_link(?APP, [], #{}),
    unlink(Sup),
    try
        {ok, _} = wa_raft_sup:start_partition(Sup, #{
            table => ?TABLE,
            partition => ?PARTITION,
            log_module => wa_raft_log_gate,
            storage_module => wa_raft_storage_ets
        }),
        Server = wa_raft_server:default_name(?TABLE, ?PARTITION),
        Acceptor = wa_raft_acceptor:default_name(?TABLE, ?PARTITION),
        Self = #raft_identity{name = Server, node = node()},
        Config = wa_raft_server:make_config([Self]),
        ok = wa_raft_server:bootstrap(Server, #raft_log_pos{index = 1, term = 1}, Config, #{}),
        ok = await_state(Server, leader, 5000),
        %% The new term's first entry establishes the leader's quorum.
        ?assertNotMatch({error, _}, commit(Acceptor, warmup)),
        Fun(Server, Acceptor)
    after
        wa_raft_log_gate:clear(),
        Monitor = erlang:monitor(process, Sup),
        exit(Sup, shutdown),
        receive {'DOWN', Monitor, process, Sup, _} -> ok end,
        [ok = application:unset_env(?APP, Key) || {Key, _} <- Env],
        ok = file:del_dir_r(Dir)
    end.

commit(Acceptor, Name) ->
    wa_raft_acceptor:commit(Acceptor, {make_ref(), {write, ?TABLE, Name, Name}}, 10000).

commit_async(Acceptor, Name) ->
    Parent = self(),
    spawn(fun () -> Parent ! {committed, Name, commit(Acceptor, Name)} end),
    ok.

await_commit(Name, TimeoutMs) ->
    receive
        {committed, Name, Result} -> Result
    after TimeoutMs ->
        timeout
    end.

await_gate_append() ->
    case maybe_gate_append(5000) of
        none -> error(no_append);
        Appender -> Appender
    end.

maybe_gate_append(TimeoutMs) ->
    receive
        {gate_append, Appender, _Entries} -> Appender
    after TimeoutMs ->
        none
    end.

log_last(Server) ->
    wa_raft_server:status(Server, log_last).

wa_raft_log_ets_get(Index) ->
    Log = #raft_log{
        name = wa_raft_log:default_name(?TABLE, ?PARTITION),
        application = ?APP,
        table = ?TABLE,
        partition = ?PARTITION,
        provider = wa_raft_log_gate
    },
    wa_raft_log_ets:get(Log, Index).

await_restart(Server, Before, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    await_restart_until(Server, Before, Deadline).

await_restart_until(Server, Before, Deadline) ->
    case whereis(Server) of
        Pid when is_pid(Pid), Pid =/= Before ->
            ok;
        _ ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    timer:sleep(10),
                    await_restart_until(Server, Before, Deadline);
                false ->
                    {not_restarted_within_ms, Deadline}
            end
    end.

await_state(Server, State, TimeoutMs) ->
    await_state(Server, State, erlang:monotonic_time(millisecond) + TimeoutMs, undefined).

await_state(Server, State, Deadline, Last) ->
    case wa_raft_server:status(Server, state) of
        State ->
            ok;
        Other ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    timer:sleep(10),
                    await_state(Server, State, Deadline, Other);
                false ->
                    {still, Last}
            end
    end.

tmp_dir() ->
    Dir = filename:join(
        os:getenv("TMPDIR", "/tmp"),
        "wa_raft_server_async_append_test_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = file:make_dir(Dir),
    Dir.
