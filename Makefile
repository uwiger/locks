.PHONY: all clean compile test doc

all: compile

compile:
	rebar compile

clean:
	rebar clean

test:
	rebar eunit

doc:
	rebar doc
