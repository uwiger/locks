.PHONY: all clean compile test doc deps

all: compile

deps:
	rebar get-deps

compile: deps
	rebar compile

clean:
	rebar clean
	rm doc/*.md doc/*.png doc/stylesheet.css

examples: compile
	cd examples
	rebar compile

test:
	rebar clean compile eunit

test_debug:
	rebar clean compile eunit eunit_compile_opts="\[\{d,'DEBUG'\}\]"

doc:
	rebar get-deps compile doc
