-include("locks.hrl").

-type transaction_status() :: no_locks
                            | {have_all_locks, list()}
                            | waiting
                            | {cannot_serve, list()}.

-record(req, {object,
              mode,
              nodes,
              claim_no = 0,
              require = all}).

-type monitored_nodes() :: [{node(), reference()}].
-type down_nodes()      :: [node()].

-record(state, {
          locks            :: ets:tab(),
          agents           :: ets:tab(),
          interesting = [] :: [lock_id()],
          claim_no = 0     :: integer(),
          requests         :: ets:tab(),
          down = []        :: down_nodes(),
          monitored = []   :: monitored_nodes(),
          await_nodes = false :: boolean(),
          monitor_nodes = false :: boolean(),
          pending          :: ets:tab(),
          sync = []        :: [#lock{}],
          client           :: pid(),
          client_mref      :: reference(),
          options = []     :: [option()],
          notify = []      :: [pid()],
          awaiting_all = []:: [{pid(), reference() | async}],
          answer           :: locking | waiting | done,
          deadlocks = []   :: deadlocks(),
          have_all = false :: boolean(),
          status = no_locks :: transaction_status(),
          check = false     :: false | {true, [any()]},
          handle_locks = false :: boolean()
         }).

-define(costly_event(E),
        case erlang:trace_info({?MODULE,event,3}, traced) of
            {_, false} -> ok;
            _          -> event(?LINE, E, none)
        end).

-define(event(E), event(?LINE, E, none)).
-define(event(E, S), event(?LINE, E, S)).

event(_Line, _Event, _State) ->
    ok.
