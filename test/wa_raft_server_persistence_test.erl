%%% Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.
%%%
%%% This source code is licensed under the Apache 2.0 license found in
%%% the LICENSE file in the root directory of this source tree.

-module(wa_raft_server_persistence_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("wa_raft/include/wa_raft.hrl").
-include_lib("wa_raft/include/wa_raft_rpc.hrl").

%% Used as the distribution module so RPCs are delivered to the test process.
-export([cast/3]).

-define(TERM, 5).
-define(CANDIDATE_NODE, 'candidate@host').
-define(CANDIDATE, #raft_identity{name = candidate_raft_server, node = ?CANDIDATE_NODE}).

cast(Destination, _Identifier, Message) ->
    self() ! {?MODULE, cast, Destination, Message},
    ok.

%%------------------------------------------------------------------------------
%% Vote grants
%%------------------------------------------------------------------------------

vote_is_granted_when_vote_is_persisted_test() ->
    Data = data("unused"),
    NewData = Data#raft_state{voted_for = ?CANDIDATE_NODE},
    Result = wa_raft_server:vote_grant_decision(follower, ?CANDIDATE, ok, Data, NewData),
    ?assertEqual(?CANDIDATE_NODE, (resulting_data(Result, Data))#raft_state.voted_for),
    ?assertEqual(
        [{{candidate_raft_server, ?CANDIDATE_NODE}, ?RAFT_NAMED_RPC(?VOTE, ?TERM, test_raft_server, node(), {true})}],
        sent_rpcs()
    ).

vote_is_withheld_when_vote_persist_fails_test() ->
    Data = data("unused"),
    NewData = Data#raft_state{voted_for = ?CANDIDATE_NODE},
    Result = wa_raft_server:vote_grant_decision(follower, ?CANDIDATE, {error, {sync, eio}}, Data, NewData),
    % Neither keep the unpersisted vote allocation nor send any vote.
    ?assertEqual(
        {undefined, []},
        {(resulting_data(Result, Data))#raft_state.voted_for, sent_rpcs()}
    ).

%%------------------------------------------------------------------------------
%% Enable command
%%------------------------------------------------------------------------------

enable_moves_to_stalled_when_enable_is_persisted_test() ->
    with_tmp_dir(fun (Dir) ->
        PartitionPath = filename:join(Dir, "partition"),
        Data = (data(PartitionPath))#raft_state{disable_reason = "corruption detected"},
        From = {self(), make_ref()},
        Result = wa_raft_server:disabled({call, From}, ?ENABLE_COMMAND, Data),
        ?assertEqual({next_state, stalled, Data#raft_state{disable_reason = undefined}, {reply, From, ok}}, Result),
        {ok, Loaded} = wa_raft_durable_state:load(#raft_state{name = test_raft_server, partition_path = PartitionPath}),
        ?assertEqual(undefined, Loaded#raft_state.disable_reason)
    end).

enable_is_refused_when_enable_persist_fails_test() ->
    with_tmp_dir(fun (Dir) ->
        % A partition path below a regular file cannot be created, so storing
        % the durable state fails.
        NotADir = filename:join(Dir, "not_a_dir"),
        ok = file:write_file(NotADir, <<>>),
        Data = (data(filename:join(NotADir, "partition")))#raft_state{disable_reason = "corruption detected"},
        From = {self(), make_ref()},
        Result = wa_raft_server:disabled({call, From}, ?ENABLE_COMMAND, Data),
        ?assertEqual({keep_state_and_data, {reply, From, {error, persist_failed}}}, Result)
    end).

%%------------------------------------------------------------------------------
%% Disable reason
%%------------------------------------------------------------------------------

disable_reason_is_persisted_without_retry_test() ->
    with_tmp_dir(fun (Dir) ->
        PartitionPath = filename:join(Dir, "partition"),
        Data = (data(PartitionPath))#raft_state{disable_reason = "corruption detected"},
        ?assertEqual({keep_state, Data}, wa_raft_server:persist_disable_reason(Data)),
        ?assertEqual("corruption detected", loaded_disable_reason(PartitionPath))
    end).

disable_reason_persist_is_retried_until_it_succeeds_test() ->
    with_tmp_dir(fun (Dir) ->
        % A partition path below a regular file cannot be created, so storing
        % the durable state fails until the file is replaced by a directory.
        Blocker = filename:join(Dir, "blocker"),
        ok = file:write_file(Blocker, <<>>),
        PartitionPath = filename:join(Blocker, "partition"),
        Data = (data(PartitionPath))#raft_state{disable_reason = "corruption detected"},
        % The replica stays disabled in memory and schedules another attempt.
        ?assertMatch(
            {keep_state, Data, [{state_timeout, RetryMs, persist_disable_reason}]} when RetryMs > 0,
            wa_raft_server:persist_disable_reason(Data)
        ),
        ok = file:delete(Blocker),
        ok = file:make_dir(Blocker),
        ?assertEqual({keep_state, Data}, wa_raft_server:disabled(state_timeout, persist_disable_reason, Data)),
        ?assertEqual("corruption detected", loaded_disable_reason(PartitionPath))
    end).

%%------------------------------------------------------------------------------
%% Helpers
%%------------------------------------------------------------------------------

loaded_disable_reason(PartitionPath) ->
    {ok, Loaded} = wa_raft_durable_state:load(#raft_state{name = test_raft_server, partition_path = PartitionPath}),
    Loaded#raft_state.disable_reason.

data(PartitionPath) ->
    #raft_state{
        name = test_raft_server,
        self = #raft_identity{name = test_raft_server, node = node()},
        identifier = #raft_identifier{application = test_app, table = test_table, partition = 1},
        table = test_table,
        partition = 1,
        partition_path = PartitionPath,
        distribution_module = ?MODULE,
        current_term = ?TERM,
        voted_for = undefined
    }.

%% The data a gen_statem keeps after a state callback returns `Result'.
resulting_data(keep_state_and_data, Data) -> Data;
resulting_data({keep_state_and_data, _Actions}, Data) -> Data;
resulting_data({keep_state, NewData}, _Data) -> NewData;
resulting_data({keep_state, NewData, _Actions}, _Data) -> NewData.

sent_rpcs() ->
    receive
        {?MODULE, cast, Destination, Message} -> [{Destination, Message} | sent_rpcs()]
    after 0 ->
        []
    end.

with_tmp_dir(Fun) ->
    Dir = filename:join(
        os:getenv("TMPDIR", "/tmp"),
        "wa_raft_server_persistence_test_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = file:make_dir(Dir),
    try
        Fun(Dir)
    after
        file:del_dir_r(Dir)
    end.
