.PHONY: all clean compile test doc

all: compile

compile:
	rebar compile

clean:
	rebar clean
	rm doc/*.md doc/*.png doc/stylesheet.css

test:
	rebar clean compile eunit

test_debug:
	rebar clean compile eunit eunit_compile_opts="\[\{d,'DEBUG'\}\]"

doc:
	rebar get-deps compile doc
