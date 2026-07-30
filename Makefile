# Local parity with .github/workflows/ci.yml.
#
# rebar3 aliases cannot mix profiles in one invocation (e.g. default
# dialyzer + `as test` dialyzer), so the full suite is orchestrated here.

REBAR3 ?= rebar3

.PHONY: all compile dialyzer dialyzer-test eunit ct test ci

all: compile

compile:
	$(REBAR3) compile

dialyzer:
	$(REBAR3) dialyzer

# Suites + gdict example apps (test profile PLT apps: ct/eunit/tools/…).
dialyzer-test:
	$(REBAR3) as test dialyzer

eunit:
	$(REBAR3) eunit

# Structured CT only (random_netsplits stays quarantined). peer needs epmd.
ct:
	@epmd -daemon 2>/dev/null || true
	$(REBAR3) ct

# Full CI steps: compile, both dialyzer profiles, eunit, ct.
test: compile dialyzer dialyzer-test eunit ct

ci: test
