.PHONY: all clean compile test doc

all: compile

compile:
	rebar compile

clean:
	rebar clean
	rm doc/*.md doc/*.png doc/stylesheet.css

test:
	rebar eunit

doc:
	rebar get-deps compile doc
