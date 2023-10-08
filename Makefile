#
# Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
# Copyright 2015 Panagiotis Papadomitsos. All Rights Reserved.
#

# .DEFAULT_GOAL can be overridden in custom.mk if "all" is not the desired
# default

.DEFAULT_GOAL := all

# Build targets
.PHONY: all test dialyzer xref spec dist travis

# Run targets
.PHONY: shell shell-master shell-slave

# Misc targets
.PHONY: clean testclean distclean tags rebar docker docker-test docker-test-ssl docker-test-ipv6 docker-test-ipv6-ssl

PROJ = $(shell ls -1 src/*.src | sed -e 's/src//' | sed -e 's/\.app\.src//' | tr -d '/')

TYPER = $(shell which typer)

REBAR = rebar3

OTP_RELEASE = $(shell escript otp-release.escript)

PLT_FILE = $(CURDIR)/_plt/rebar3_$(OTP_RELEASE)_plt

# ============================
# Integration test with docker
# ============================

DOCKER_IMAGE ?= genrpc
docker:
	@docker build --network host --pull -t $(DOCKER_IMAGE) .

NODES ?= 3
docker-test: docker
	@./test/integration/integration-tests.sh $(NODES)

docker-test-ssl: docker
	@env LISTEN="0.0.0.0" SSL=true ./test/integration/integration-tests.sh $(NODES)

docker-test-ipv6: docker
	@env LISTEN="::" ./test/integration/integration-tests.sh $(NODES)

docker-test-ipv6-ssl: docker
	@env LISTEN="::" SSL=true ./test/integration/integration-tests.sh $(NODES)

docker-cluster: docker
	@./test/integration/integration-tests.sh $(NODES) false

# =============================================================================
# Build targets
# =============================================================================

all:
	$(REBAR) compile

test: epmd
	@REBAR_PROFILE=test $(REBAR) do eunit, ct  --name gen_rpc_master@127.0.0.1 --cover, cover

dialyzer: $(PLT_FILE)
	@$(REBAR) do compile, dialyzer

xref:
	@$(REBAR) xref

spec: dialyzer
	@$(TYPER) --annotate-inc-files -I ./include --plt $(PLT_FILE) -r src/

dist: test
	@$(REBAR) do dialyzer, xref

# =============================================================================
# Misc targets
# =============================================================================

clean: $(REBAR)
	@$(REBAR) clean
	@rm -f rebar.lock

distclean: $(REBAR)
	@rm -rf _build _plt .rebar Mnesia* mnesia* data/ temp-data/ rebar.lock
	@find . -name erl_crash.dump -type f -delete
	@$(REBAR) clean -a

testclean:
	@rm -fr _build/test && rm -rf ./test/*.beam
	@find log/ct -maxdepth 1 -name ct_run* -type d -cmin +360 -exec rm -fr {} \; 2> /dev/null || true

epmd:
	@pgrep epmd 2> /dev/null > /dev/null || epmd -daemon || true

tags:
	find src _build/default/lib -name "*.[he]rl" -print | etags -

$(PLT_FILE):
	@$(REBAR) do dialyzer || true
