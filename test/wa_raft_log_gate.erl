%%% Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.
%%%
%%% This source code is licensed under the Apache 2.0 license found in
%%% the LICENSE file in the root directory of this source tree.

-module(wa_raft_log_gate).

%% An ETS log whose appends a test can hold. While a test owns the gate, each
%% append sends it {gate_append, Appender, Entries} and waits for the test to
%% answer with the append's result, `ok' to store the entries or any other term
%% to return it. A test can also make trims stop short of an index, as a log
%% that defers some of the work does. Everything else is wa_raft_log_ets.

-behaviour(wa_raft_log).

-export([
    first_index/1,
    last_index/1,
    fold/6,
    fold_terms/5,
    get/2,
    term/2,
    config/1
]).
-export([
    append/4
]).
-export([
    init/1,
    open/1,
    close/2,
    reset/3,
    truncate/3,
    trim/3,
    flush/1
]).
-export([
    set_owner/1,
    fail_truncate/1,
    limit_trim/1,
    clear/0
]).

set_owner(Pid) ->
    case ets:info(?MODULE) of
        undefined -> ets:new(?MODULE, [named_table, public, set]);
        _ -> ok
    end,
    persistent_term:put({?MODULE, owner}, Pid).

%% Makes every truncate return {error, Reason}.
fail_truncate(Reason) ->
    persistent_term:put({?MODULE, truncate}, Reason).

%% Makes every trim past Limit trim only up to Limit and say so, as a log
%% that defers work does; `undefined' trims as asked again.
limit_trim(undefined) ->
    _ = persistent_term:erase({?MODULE, trim_limit}),
    ok;
limit_trim(Limit) ->
    persistent_term:put({?MODULE, trim_limit}, Limit).

%% Releases appends still held, failing them, so that a failed test does not
%% leave the server waiting on the gate.
clear() ->
    _ = persistent_term:erase({?MODULE, owner}),
    _ = persistent_term:erase({?MODULE, truncate}),
    _ = persistent_term:erase({?MODULE, trim_limit}),
    case ets:info(?MODULE) of
        undefined ->
            ok;
        _ ->
            [Appender ! {gate, {error, gate_cleared}} || {Appender} <- ets:tab2list(?MODULE)],
            true = ets:delete(?MODULE),
            ok
    end.

append(View, Entries, Mode, Priority) ->
    case persistent_term:get({?MODULE, owner}, undefined) of
        undefined ->
            wa_raft_log_ets:append(View, Entries, Mode, Priority);
        Owner ->
            true = ets:insert(?MODULE, {self()}),
            Owner ! {gate_append, self(), Entries},
            try
                gate_result(View, Entries, Mode, Priority)
            after
                catch ets:delete(?MODULE, self())
            end
    end.

gate_result(View, Entries, Mode, Priority) ->
    receive
        {gate, ok} ->
            wa_raft_log_ets:append(View, Entries, Mode, Priority);
        {gate, Result} ->
            Result
    end.

truncate(Log, Index, State) ->
    case persistent_term:get({?MODULE, truncate}, undefined) of
        undefined -> wa_raft_log_ets:truncate(Log, Index, State);
        Reason -> {error, Reason}
    end.

first_index(Log) -> wa_raft_log_ets:first_index(Log).
last_index(Log) -> wa_raft_log_ets:last_index(Log).
fold(Log, First, Last, SizeLimit, Fun, Acc) -> wa_raft_log_ets:fold(Log, First, Last, SizeLimit, Fun, Acc).
fold_terms(Log, First, Last, Fun, Acc) -> wa_raft_log_ets:fold_terms(Log, First, Last, Fun, Acc).
get(Log, Index) -> wa_raft_log_ets:get(Log, Index).
term(Log, Index) -> wa_raft_log_ets:term(Log, Index).
config(Log) -> wa_raft_log_ets:config(Log).
init(Log) -> wa_raft_log_ets:init(Log).
open(Log) -> wa_raft_log_ets:open(Log).
close(Log, State) -> wa_raft_log_ets:close(Log, State).
reset(Log, Position, State) -> wa_raft_log_ets:reset(Log, Position, State).
trim(Log, Index, State) ->
    case persistent_term:get({?MODULE, trim_limit}, undefined) of
        Limit when is_integer(Limit), Limit < Index ->
            {ok, NewState} = wa_raft_log_ets:trim(Log, Limit, State),
            {ok, Limit, NewState};
        _ ->
            wa_raft_log_ets:trim(Log, Index, State)
    end.
flush(Log) -> wa_raft_log_ets:flush(Log).
