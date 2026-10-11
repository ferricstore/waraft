%%% Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.
%%%
%%% This source code is licensed under the Apache 2.0 license found in
%%% the LICENSE file in the root directory of this source tree.

-module(wa_raft_server_adaptive_batch_test).

-include_lib("eunit/include/eunit.hrl").

fixed_window_delays_when_adaptive_disabled_test() ->
    ?assertEqual(delay, wa_raft_server:commit_batch_decision_for_test(6, 10000, false, false, 1, false)).

adaptive_flushes_first_idle_commit_test() ->
    ?assertEqual(flush, wa_raft_server:commit_batch_decision_for_test(6, 10000, true, false, 1, false)).

adaptive_flushes_first_idle_commit_even_when_mailbox_has_backlog_test() ->
    ?assertEqual(flush, wa_raft_server:commit_batch_decision_for_test(6, 10000, true, false, 1, true)).

adaptive_keeps_existing_batch_until_timer_or_max_test() ->
    ?assertEqual(delay, wa_raft_server:commit_batch_decision_for_test(6, 10000, true, true, 2, false)).

disabled_window_flushes_immediately_test() ->
    ?assertEqual(flush, wa_raft_server:commit_batch_decision_for_test(0, 10000, true, false, 1, true)).

max_batch_flushes_immediately_test() ->
    ?assertEqual(flush, wa_raft_server:commit_batch_decision_for_test(6, 2, true, true, 3, true)).
