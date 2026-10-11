%%% Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.
%%%
%%% This source code is licensed under the Apache 2.0 license found in
%%% the LICENSE file in the root directory of this source tree.
%%%
%%% This module implements functions for storing / loading persistent state.

-module(wa_raft_durable_state).
-compile(warn_missing_spec_all).

-include_lib("wa_raft/include/wa_raft.hrl").
-include_lib("wa_raft/include/wa_raft_logger.hrl").

-export([
    load/1,
    store/1,
    sync/1
]).

-ifdef(TEST).
-export([
    dir_sync_result/1,
    start_file_op_trace/0,
    stop_file_op_trace/0
]).
-endif.

%% Test seam: in TEST builds, record the durability-relevant file operations
%% completed by store/1 so that tests can check their order. A no-op otherwise.
-ifdef(TEST).
-define(TRACE_FILE_OP(Op), trace_file_op(Op)).
-else.
-define(TRACE_FILE_OP(Op), ok).
-endif.

-spec load(StateIn :: #raft_state{}) -> {ok, StateOut :: #raft_state{}} | no_state | {error, Reason :: term()}.
load(#raft_state{name = Name, partition_path = PartitionPath} = State) ->
    StateItems = [
        {current_term,   fun is_integer/1, fun (V, S) -> S#raft_state{current_term = V} end,   required},
        {voted_for,      fun is_atom/1,    fun (V, S) -> S#raft_state{voted_for = V} end,      required},
        {disable_reason, undefined,        fun (V, S) -> S#raft_state{disable_reason = V} end, undefined}
    ],
    StateFile = filename:join(PartitionPath, ?STATE_FILE_NAME),
    case file:consult(StateFile) of
        {ok, [{crc, SavedCRC} | StateTerms]} ->
            case erlang:crc32(term_to_binary(StateTerms, [{minor_version, 1}, deterministic])) of
                SavedCRC ->
                    try
                        {ok, lists:foldl(
                            fun ({Item, Validator, Updater, Default}, StateN) ->
                                    case proplists:lookup(Item, StateTerms) of
                                        none when Default =:= required ->
                                            ?RAFT_LOG_ERROR("~p read state file but cannot find ~p.", [Name, Item]),
                                            throw({error, {missing, Item}});
                                        none ->
                                            Updater(Default, StateN);
                                        {Item, Value} ->
                                            case Validator =:= undefined orelse Validator(Value) of
                                                true ->
                                                    Updater(Value, StateN);
                                                false ->
                                                    ?RAFT_LOG_ERROR("~p read state file but ~p has an invalid value `~p`.", [Name, Item, Value]),
                                                    throw({error, {invalid, Item}})
                                            end
                                    end
                            end, State, StateItems)}
                    catch
                        throw:{error, Reason} -> {error, Reason}
                    end;
                InvalidCRC ->
                    ?RAFT_LOG_ERROR("~p read state file but CRCs did not match. (saved crc: ~p, computed crc: ~p)", [Name, SavedCRC, InvalidCRC]),
                    {error, invalid_crc}
            end;
        {ok, _} ->
            ?RAFT_LOG_ERROR("~p read state file but no CRC was found", [Name]),
            {error, no_crc};
        {error, enoent} ->
            ?RAFT_LOG_NOTICE("~p is not loading non-existent state file.", [Name]),
            no_state;
        {error, Reason} ->
            ?RAFT_LOG_ERROR("~p could not read state file due to ~p.", [Name, Reason]),
            {error, Reason}
    end.

-spec store(#raft_state{}) -> ok | {error, Reason :: term()}.
store(#raft_state{name = Name, table = Table, partition_path = PartitionPath, current_term = CurrentTerm, voted_for = VotedFor, disable_reason = DisableReason}) ->
    StateList = [
        {current_term, CurrentTerm},
        {voted_for, VotedFor},
        {disable_reason, DisableReason}
    ],
    StateListWithCRC = [{crc, erlang:crc32(term_to_binary(StateList, [{minor_version, 1}, deterministic]))} | StateList],
    StateIO = [io_lib:format("~p.~n", [Term]) || Term <- StateListWithCRC],
    StateFile = filename:join(PartitionPath, ?STATE_FILE_NAME),
    StateFileTemp = [StateFile, ".temp"],
    case filelib:ensure_dir(StateFile) of
        ok ->
            % The new state must be on stable storage before it replaces the
            % old state file, and the rename itself must be on stable storage
            % before the caller acts on the new state (e.g. grants a vote).
            case write_and_sync_file(StateFileTemp, StateIO) of
                ok ->
                    case file:rename(StateFileTemp, StateFile) of
                        ok ->
                            ?TRACE_FILE_OP({rename, StateFileTemp, StateFile}),
                            case dir_sync_result(sync_dir(filename:dirname(StateFile))) of
                                ok ->
                                    ok;
                                {error, Reason} ->
                                    ?RAFT_COUNT(Table, {'server.persist_state.error.sync_dir', Reason}),
                                    ?RAFT_LOG_ERROR("~p failed to sync state file directory due to ~p.", [Name, Reason]),
                                    {error, {sync_dir, Reason}}
                            end;
                        {error, Reason} ->
                            ?RAFT_COUNT(Table, {'server.persist_state.error.rename', Reason}),
                            ?RAFT_LOG_ERROR("~p failed to rename temporary state file due to ~p.", [Name, Reason]),
                            {error, {rename, Reason}}
                    end;
                {error, {sync, Reason}} ->
                    ?RAFT_COUNT(Table, {'server.persist_state.error.sync', Reason}),
                    ?RAFT_LOG_ERROR("~p failed to sync temporary state file due to ~p.", [Name, Reason]),
                    {error, {sync, Reason}};
                {error, {write, Reason}} ->
                    ?RAFT_COUNT(Table, {'server.persist_state.error.write', Reason}),
                    ?RAFT_LOG_ERROR("~p failed to write current state to temporary file due to ~p.", [Name, Reason]),
                    {error, {write, Reason}}
            end;
        {error, Reason} ->
            ?RAFT_COUNT(Table, {'server.persist_state.error.ensure_dir', Reason}),
            ?RAFT_LOG_ERROR("~p failed to ensure directory exists due to ~p.", [Name, Reason]),
            {error, {ensure_dir, Reason}}
    end.

-spec sync(StateIn :: #raft_state{}) -> ok.
sync(#raft_state{partition_path = PartitionPath}) ->
    StateFile = filename:join(PartitionPath, ?STATE_FILE_NAME),
    case prim_file:open(StateFile, [read, binary]) of
        {ok, Fd} ->
            prim_file:sync(Fd),
            prim_file:close(Fd),
            ok;
        _ ->
            ok
    end.

%% Write the provided data to the file at the provided path and flush it to
%% stable storage.
-spec write_and_sync_file(Path :: file:name_all(), Data :: iodata()) -> ok | {error, {write | sync, Reason :: term()}}.
write_and_sync_file(Path, Data) ->
    case file:open(Path, [write, raw, binary]) of
        {ok, Fd} ->
            Result = case file:write(Fd, Data) of
                ok ->
                    case file:sync(Fd) of
                        ok ->
                            ?TRACE_FILE_OP({sync_file, Path}),
                            ok;
                        {error, Reason} ->
                            {error, {sync, Reason}}
                    end;
                {error, Reason} ->
                    {error, {write, Reason}}
            end,
            case file:close(Fd) of
                {error, CloseReason} when Result =:= ok -> {error, {write, CloseReason}};
                _ -> Result
            end;
        {error, Reason} ->
            {error, {write, Reason}}
    end.

%% Flush the entries of the provided directory (e.g. a file just renamed into
%% it) to stable storage.
-spec sync_dir(Dir :: file:name_all()) -> ok | {error, Reason :: term()}.
sync_dir(Dir) ->
    case file:open(Dir, [read, raw, directory]) of
        {ok, Fd} ->
            SyncResult = file:sync(Fd),
            CloseResult = file:close(Fd),
            case SyncResult of
                ok ->
                    ?TRACE_FILE_OP({sync_dir, Dir}),
                    CloseResult;
                {error, _} ->
                    SyncResult
            end;
        {error, _} = OpenError ->
            OpenError
    end.

%% Some platforms and filesystems cannot fsync a directory at all and report
%% this as `einval' (e.g. Linux on filesystems without directory fsync support)
%% or as "operation not supported" (ENOTSUP, which surfaces as `enotsup' or
%% `eopnotsupp' depending on the platform's errno definitions). Nothing more
%% can be done to make the rename durable there, so these are not failures.
%% Any other error (e.g. `eio') means the rename may not survive a crash and
%% is returned.
-spec dir_sync_result(Result :: ok | {error, Reason :: term()}) -> ok | {error, Reason :: term()}.
dir_sync_result({error, Reason}) when Reason =:= einval; Reason =:= enotsup; Reason =:= eopnotsupp ->
    ok;
dir_sync_result(Result) ->
    Result.

%%------------------------------------------------------------------------------
%% Test seam
%%------------------------------------------------------------------------------

-ifdef(TEST).
-define(FILE_OP_TRACE_KEY, {?MODULE, file_op_trace}).

-type file_op() ::
    {sync_file, Path :: file:name_all()} |
    {rename, Source :: file:name_all(), Destination :: file:name_all()} |
    {sync_dir, Dir :: file:name_all()}.

%% Start recording the file operations completed by store/1 in this process.
-spec start_file_op_trace() -> ok.
start_file_op_trace() ->
    put(?FILE_OP_TRACE_KEY, []),
    ok.

%% Stop recording and return the recorded file operations in the order in
%% which they completed.
-spec stop_file_op_trace() -> [file_op()].
stop_file_op_trace() ->
    case erase(?FILE_OP_TRACE_KEY) of
        undefined -> [];
        Ops -> lists:reverse(Ops)
    end.

-spec trace_file_op(Op :: file_op()) -> ok.
trace_file_op(Op) ->
    case get(?FILE_OP_TRACE_KEY) of
        undefined -> ok;
        Ops -> put(?FILE_OP_TRACE_KEY, [Op | Ops]), ok
    end.
-endif.
