%% This is to support stack traces on pre-OTP21 versions
%% while avoiding compiler warnings on later versions.
-ifdef(OTP_RELEASE).
-define(_catch_(ErrorType, Error, ErrorStackTrace),
        catch ErrorType:Error:ErrorStackTrace ->).
-else.
-define(_catch_(ErrorType, Error, ErrorStackTrace),
        catch ErrorType:Error ->
            ErrorStackTrace = erlang:get_stacktrace(),).
-endif.
