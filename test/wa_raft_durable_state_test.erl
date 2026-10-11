%%% Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.
%%%
%%% This source code is licensed under the Apache 2.0 license found in
%%% the LICENSE file in the root directory of this source tree.

-module(wa_raft_durable_state_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("wa_raft/include/wa_raft.hrl").

store_syncs_temp_file_before_rename_then_syncs_directory_test() ->
    with_tmp_dir(fun (Dir) ->
        PartitionPath = filename:join(Dir, "partition"),
        StateFile = filename:join(PartitionPath, ?STATE_FILE_NAME),
        TempFile = StateFile ++ ".temp",
        ok = wa_raft_durable_state:start_file_op_trace(),
        Result = wa_raft_durable_state:store(state(PartitionPath, 7, 'candidate@host', undefined)),
        Ops = [flatten_paths(Op) || Op <- wa_raft_durable_state:stop_file_op_trace()],
        ?assertEqual(ok, Result),
        ?assertEqual(
            [
                {sync_file, TempFile},
                {rename, TempFile, StateFile},
                {sync_dir, PartitionPath}
            ],
            Ops
        )
    end).

store_then_load_round_trips_latest_state_test() ->
    with_tmp_dir(fun (Dir) ->
        PartitionPath = filename:join(Dir, "partition"),
        ?assertEqual(ok, wa_raft_durable_state:store(state(PartitionPath, 1, undefined, undefined))),
        ?assertEqual(ok, wa_raft_durable_state:store(state(PartitionPath, 42, 'candidate@host', "corruption detected"))),
        {ok, Loaded} = wa_raft_durable_state:load(#raft_state{name = test_raft_server, partition_path = PartitionPath}),
        ?assertEqual(
            {42, 'candidate@host', "corruption detected"},
            {Loaded#raft_state.current_term, Loaded#raft_state.voted_for, Loaded#raft_state.disable_reason}
        ),
        ?assertNot(filelib:is_file(filename:join(PartitionPath, ?STATE_FILE_NAME) ++ ".temp"))
    end).

unsupported_directory_sync_errors_are_ignored_test() ->
    ?assertEqual(ok, wa_raft_durable_state:dir_sync_result(ok)),
    ?assertEqual(ok, wa_raft_durable_state:dir_sync_result({error, einval})),
    ?assertEqual(ok, wa_raft_durable_state:dir_sync_result({error, enotsup})),
    ?assertEqual(ok, wa_raft_durable_state:dir_sync_result({error, eopnotsupp})).

other_directory_sync_errors_are_returned_test() ->
    ?assertEqual({error, eio}, wa_raft_durable_state:dir_sync_result({error, eio})),
    ?assertEqual({error, eacces}, wa_raft_durable_state:dir_sync_result({error, eacces})).

%%------------------------------------------------------------------------------
%% Helpers
%%------------------------------------------------------------------------------

state(PartitionPath, Term, VotedFor, DisableReason) ->
    #raft_state{
        name = test_raft_server,
        table = test_table,
        partition_path = PartitionPath,
        current_term = Term,
        voted_for = VotedFor,
        disable_reason = DisableReason
    }.

flatten_paths(Op) ->
    list_to_tuple([element(1, Op) | [filename:flatten(Path) || Path <- tl(tuple_to_list(Op))]]).

with_tmp_dir(Fun) ->
    Dir = filename:join(
        os:getenv("TMPDIR", "/tmp"),
        "wa_raft_durable_state_test_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = file:make_dir(Dir),
    try
        Fun(Dir)
    after
        file:del_dir_r(Dir)
    end.
