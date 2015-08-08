.PHONY: all clean compile test doc deps

all: compile

deps:
	rebar get-deps

compile: deps
	rebar compile

debug: clean deps
	rebar compile erl_opts="\[\{d,DEBUG\}\]"
	cd examples
	rebar compile erl_opts="\[\{d,DEBUG\}\]"

clean:
	rebar clean
	rm -f doc/*.md doc/*.png doc/stylesheet.css

examples: compile
	cd examples
	rebar compile

test:
	rebar clean compile eunit ct

test_debug:
	rebar clean compile eunit ct eunit_compile_opts="\[\{d,'DEBUG'\}\]"

doc:
	rebar get-deps compile doc
