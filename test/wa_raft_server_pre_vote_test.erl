%%% Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.
%%%
%%% This source code is licensed under the Apache 2.0 license found in
%%% the LICENSE file in the root directory of this source tree.

-module(wa_raft_server_pre_vote_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("wa_raft/include/wa_raft.hrl").

-define(APP, wa_raft_pre_vote_test).
-define(TABLE, wa_raft_pre_vote_test).
-define(PARTITION, 1).
-define(TIMEOUT_MS, 100).
-define(TIMEOUT_MS_MAX, 200).

%% A replica that loses leadership (a resignation here; a restart of a
%% server whose log survives does the same) waits out an election timeout as
%% a follower and then stands. With pre-vote it first asks its peers whether
%% it could win. The only member of a cluster is a majority on its own and
%% has no peers to ask, so it must not wait for their replies.
sole_member_elects_itself_with_pre_vote_test_() ->
    {timeout, 30, fun () ->
        with_partition(1, fun (Server) ->
            ok = wa_raft_server:resign(Server),
            ?assertEqual(ok, await_state(Server, leader, 5000))
        end)
    end}.

%% A member of a larger cluster still needs its peers' pre-votes before it
%% advances its term; peers that never answer leave the term alone.
member_without_peers_keeps_its_term_with_pre_vote_test_() ->
    {timeout, 30, fun () ->
        with_partition(3, fun (Server) ->
            Term = wa_raft_server:status(Server, current_term),
            timer:sleep(10 * ?TIMEOUT_MS_MAX),
            ?assertEqual(candidate, wa_raft_server:status(Server, state)),
            ?assertEqual(Term, wa_raft_server:status(Server, current_term))
        end)
    end}.

%%------------------------------------------------------------------------------
%% Helpers
%%------------------------------------------------------------------------------

%% Starts the partition with pre-vote on and bootstraps it with the local
%% replica and `MemberCount - 1' peers that do not exist.
with_partition(MemberCount, Fun) ->
    Dir = tmp_dir(),
    Env = [
        {raft_database, Dir},
        {raft_election_pre_vote, true},
        {raft_election_timeout_ms, ?TIMEOUT_MS},
        {raft_election_timeout_ms_max, ?TIMEOUT_MS_MAX}
    ],
    [ok = application:set_env(?APP, Key, Value) || {Key, Value} <- Env],
    {ok, _} = application:ensure_all_started(wa_raft),
    {ok, Sup} = wa_raft_sup:start_link(?APP, [], #{}),
    unlink(Sup),
    try
        {ok, _} = wa_raft_sup:start_partition(Sup, #{
            table => ?TABLE,
            partition => ?PARTITION,
            log_module => wa_raft_log_ets,
            storage_module => wa_raft_storage_ets
        }),
        Server = wa_raft_server:default_name(?TABLE, ?PARTITION),
        Self = #raft_identity{name = Server, node = node()},
        Peers = [#raft_identity{name = Server, node = peer_node(N)} || N <- lists:seq(2, MemberCount)],
        Config = wa_raft_server:make_config([Self | Peers]),
        ok = wa_raft_server:bootstrap(Server, #raft_log_pos{index = 1, term = 1}, Config, #{}),
        case MemberCount of
            1 -> ok = await_state(Server, leader, 5000);
            _ -> ok = await_state(Server, candidate, 5000)
        end,
        Fun(Server)
    after
        Monitor = erlang:monitor(process, Sup),
        exit(Sup, shutdown),
        receive {'DOWN', Monitor, process, Sup, _} -> ok end,
        [ok = application:unset_env(?APP, Key) || {Key, _} <- Env],
        ok = file:del_dir_r(Dir)
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

peer_node(N) ->
    list_to_atom("wa_raft_pre_vote_peer" ++ integer_to_list(N) ++ "@nohost").

tmp_dir() ->
    Dir = filename:join(
        os:getenv("TMPDIR", "/tmp"),
        "wa_raft_server_pre_vote_test_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = file:make_dir(Dir),
    Dir.
