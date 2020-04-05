
-ifdef(LOCKS_DEBUG).

-ifndef(LOCKS_LOGSZ).
-define(LOCKS_LOGSZ, 10).
-endif.

-define(log(X), locks_window:log(X, ?LOCKS_LOGSZ)).

-else.
-define(log(X), ok).
-endif.
