-module(wa_raft_server_commit_deadline_test).
-include_lib("eunit/include/eunit.hrl").
-include("wa_raft.hrl").

pending_deadline_remains_earlier_than_idle_heartbeat_test() ->
    Now = erlang:monotonic_time(millisecond),
    Data = #raft_state{application = wa_raft, table = deadline_test,
        pending_high = [{undefined, noop}], commit_batch_deadline = Now + 20},
    {state_timeout, First, batch_commit} = wa_raft_server:leader_timeout_for_test(Data),
    timer:sleep(10),
    {state_timeout, Next, batch_commit} = wa_raft_server:leader_timeout_for_test(Data),
    ?assert(First =< 20),
    ?assert(Next =< First),
    ?assert(Next >= 0).

elapsed_deadline_is_not_restarted_test() ->
    Data = #raft_state{application = wa_raft, table = deadline_test,
        pending_low = [{undefined, noop}],
        commit_batch_deadline = erlang:monotonic_time(millisecond) - 10},
    ?assertEqual({state_timeout, 0, batch_commit}, wa_raft_server:leader_timeout_for_test(Data)).

idle_batch_deadline_does_not_spin_test() ->
    Data = #raft_state{application = wa_raft, table = deadline_test,
        commit_batch_deadline = erlang:monotonic_time(millisecond) - 10},
    ?assertEqual({state_timeout, 120, heartbeat}, wa_raft_server:leader_timeout_for_test(Data)).

in_flight_append_does_not_spin_on_expired_batch_test() ->
    Data = #raft_state{application = wa_raft, table = deadline_test,
        pending_low = [{undefined, noop}], append_in_flight = {busy},
        commit_batch_deadline = erlang:monotonic_time(millisecond) - 10},
    ?assertEqual({state_timeout, 120, heartbeat}, wa_raft_server:leader_timeout_for_test(Data)).

handover_does_not_flush_pending_batch_test() ->
    Data = #raft_state{application = wa_raft, table = deadline_test,
        pending_high = [{undefined, noop}], handover = {node(), make_ref(), 1000},
        commit_batch_deadline = erlang:monotonic_time(millisecond) - 10},
    ?assertEqual({state_timeout, 120, heartbeat}, wa_raft_server:leader_timeout_for_test(Data)).
