%%% Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.
%%%
%%% This source code is licensed under the Apache 2.0 license found in
%%% the LICENSE file in the root directory of this source tree.

-module(wa_raft_server_trim_progress_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("wa_raft/include/wa_raft.hrl").

-define(APP, wa_raft_trim_progress_test).
-define(TABLE, wa_raft_trim_progress_test).
-define(PARTITION, 1).

%% A log may trim less than rotation asks for, or nothing yet. The log view
%% used to start at the asked index anyway, so rotation waited a whole
%% interval past it before asking again, and the entries the log kept were
%% not trimmed until then (or until a restart reread the log's first index).
a_trim_the_log_defers_is_asked_again_test_() ->
    {timeout, 30, fun () ->
        with_partition(fun (Server, Acceptor) ->
            First = log_first(Server),
            ok = wa_raft_log_gate:limit_trim(First),
            [ok = commit(Acceptor, N) || N <- lists:seq(1, 6)],
            ?assertEqual(First, provider_first()),
            ?assertEqual(First, log_first(Server)),
            ok = wa_raft_log_gate:limit_trim(undefined),
            ok = commit(Acceptor, 7),
            Trimmed = log_first(Server),
            ?assert(Trimmed > First),
            ?assertEqual(Trimmed, provider_first())
        end)
    end}.

a_trim_the_log_does_in_part_moves_the_view_that_far_test_() ->
    {timeout, 30, fun () ->
        with_partition(fun (Server, Acceptor) ->
            Partial = log_first(Server) + 2,
            ok = wa_raft_log_gate:limit_trim(Partial),
            [ok = commit(Acceptor, N) || N <- lists:seq(1, 6)],
            ?assertEqual(Partial, provider_first()),
            ?assertEqual(Partial, log_first(Server)),
            ok = wa_raft_log_gate:limit_trim(undefined),
            ok = commit(Acceptor, 7),
            Trimmed = log_first(Server),
            ?assert(Trimmed > Partial),
            ?assertEqual(Trimmed, provider_first())
        end)
    end}.

%%------------------------------------------------------------------------------
%% Helpers
%%------------------------------------------------------------------------------

with_partition(Fun) ->
    Dir = tmp_dir(),
    %% Rotate whenever two entries can go, keeping none.
    Env = [
        {raft_database, Dir},
        {raft_commit_batch_interval_ms, 0},
        {raft_max_log_records_per_file, 2},
        {raft_max_log_records, 0},
        {raft_max_retained_entries, 0}
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
        [ok = commit(Acceptor, {warmup, N}) || N <- lists:seq(1, 4)],
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
    case wa_raft_acceptor:commit(Acceptor, {make_ref(), {write, ?TABLE, Name, Name}}, 10000) of
        {error, _} = Error -> Error;
        _ -> ok
    end.

log_first(Server) ->
    wa_raft_server:status(Server, log_first).

provider_first() ->
    wa_raft_log_ets:first_index(#raft_log{
        name = wa_raft_log:default_name(?TABLE, ?PARTITION),
        application = ?APP,
        table = ?TABLE,
        partition = ?PARTITION,
        provider = wa_raft_log_gate
    }).

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
        "wa_raft_server_trim_progress_test_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = file:make_dir(Dir),
    Dir.
