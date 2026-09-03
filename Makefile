SHELL := /bin/bash
.DEFAULT_GOAL := demo

RUBY ?= ruby
RUBY_RUN := $(RUBY) -Ilib
PYTHON ?= python3
PYTHON_GRPC_PORT ?= 50051
PYTHON_GRPC := $(if $(wildcard .venv-grpc/bin/python),.venv-grpc/bin/python,$(PYTHON))

STANDARD_SERVER_SCRIPTS := \
	examples/servers/http_server.rb \
	examples/servers/sse_server.rb \
	examples/servers/streamable_http_server.rb \
	examples/servers/websocket_server.rb \
	examples/servers/graphql_server.rb \
	examples/servers/tcp_server.rb \
	examples/servers/udp_server.rb

STANDARD_CLIENT_SCRIPTS := \
	examples/http.rb \
	examples/sse.rb \
	examples/streamable_http.rb \
	examples/cli.rb \
	examples/websocket.rb \
	examples/graphql.rb \
	examples/tcp.rb \
	examples/udp.rb \
	examples/mcp.rb \
	examples/text.rb

GRPC_AVAILABLE := $(shell $(RUBY) -e 'require "grpc"; print "yes"' 2>/dev/null)
WEBRTC_AVAILABLE := $(shell $(RUBY) -e 'gem "webrtc-ruby", ">= 1.0.0"; require "webrtc"; abort unless defined?(WebRTC::RTCPeerConnection); print "yes"' 2>/dev/null)

AVAILABLE_SERVER_SCRIPTS := $(STANDARD_SERVER_SCRIPTS)
AVAILABLE_CLIENT_SCRIPTS := $(STANDARD_CLIENT_SCRIPTS)
AVAILABLE_PORTS := 8080 8081 8082 8083 8085 9000

ifneq ($(DISABLE_OPTIONAL),1)
ifeq ($(GRPC_AVAILABLE),yes)
AVAILABLE_SERVER_SCRIPTS += examples/servers/grpc_server.rb
AVAILABLE_CLIENT_SCRIPTS += examples/grpc.rb
AVAILABLE_PORTS += 50051
endif
ifeq ($(WEBRTC_AVAILABLE),yes)
AVAILABLE_SERVER_SCRIPTS += examples/servers/webrtc_server.rb
AVAILABLE_CLIENT_SCRIPTS += examples/webrtc.rb
AVAILABLE_PORTS += 8084
endif
endif

.PHONY: all demo full-demo servers full-servers examples full-examples \
	check-base-dependencies check-ruby-grpc check-python-grpc check-python-grpc-tools \
	check-dependencies dependency-report grpc-python-setup grpc-python-generate \
	grpc-python-server grpc-python-client grpc-python-demo test standard-demo

all: demo

check-base-dependencies:
	@$(RUBY) -e 'require "webrick"' || { \
		echo "WEBrick is required by the local HTTP example servers." >&2; \
		echo "Install it with: $$(ruby -e 'print RbConfig.ruby') -S gem install webrick" >&2; \
		exit 1; \
	}

check-ruby-grpc:
	@$(RUBY) -e 'require "grpc"' || { \
		echo "The Ruby gRPC client requires the grpc gem." >&2; \
		echo "Install it with Ruby 3.1+: gem install grpc" >&2; \
		exit 1; \
	}

check-python-grpc:
	@$(PYTHON_GRPC) -c 'import grpc' || { \
		echo "The Python gRPC server requires grpcio." >&2; \
		echo "Install them with: make grpc-python-setup" >&2; \
		exit 1; \
	}

check-python-grpc-tools: check-python-grpc
	@$(PYTHON_GRPC) -c 'from grpc_tools import protoc' || { \
		echo "Stub generation requires grpcio-tools." >&2; \
		echo "Install it with: make grpc-python-setup" >&2; \
		exit 1; \
	}

check-dependencies: check-base-dependencies check-ruby-grpc
	@$(RUBY) -e 'abort "Ruby 3.1+ is required by webrtc-ruby (current: #{RUBY_VERSION})" if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("3.1"); gem "webrtc-ruby", ">= 1.0.0"; require "webrtc"; abort "webrtc-ruby did not load WebRTC::RTCPeerConnection" unless defined?(WebRTC::RTCPeerConnection)' || { \
		echo "Install webrtc-ruby and libdatachannel before running the full demo." >&2; \
		exit 1; \
	}

dependency-report:
	@if [[ "$(DISABLE_OPTIONAL)" != "1" && "$(GRPC_AVAILABLE)" != "yes" ]]; then \
		echo "[skip] gRPC example: install the grpc gem (Ruby 3.1+ recommended)"; \
	fi
	@if [[ "$(DISABLE_OPTIONAL)" != "1" && "$(WEBRTC_AVAILABLE)" != "yes" ]]; then \
		echo "[skip] WebRTC example: requires Ruby 3.1+, webrtc-ruby, and libdatachannel"; \
	fi

servers: check-base-dependencies dependency-report
	@set -euo pipefail; \
	pids=(); \
	cleanup() { \
		if (($${#pids[@]})); then \
			kill "$${pids[@]}" 2>/dev/null || true; \
			wait "$${pids[@]}" 2>/dev/null || true; \
		fi; \
	}; \
	trap cleanup EXIT INT TERM; \
	for script in $(AVAILABLE_SERVER_SCRIPTS); do \
		echo "[server] $$script"; \
		$(RUBY_RUN) "$$script" & \
		pids+=("$$!"); \
	done; \
	echo "All network servers are running. Press Ctrl-C to stop them."; \
	wait

full-servers: check-dependencies
	@$(MAKE) --no-print-directory servers

examples: dependency-report
	@set -euo pipefail; \
	for script in $(AVAILABLE_CLIENT_SCRIPTS); do \
		echo; \
		echo "[example] $$script"; \
		$(RUBY_RUN) "$$script"; \
	done

full-examples: check-dependencies
	@$(MAKE) --no-print-directory examples

demo: check-base-dependencies dependency-report
	@set -euo pipefail; \
	pids=(); \
	cleanup() { \
		if (($${#pids[@]})); then \
			kill "$${pids[@]}" 2>/dev/null || true; \
			wait "$${pids[@]}" 2>/dev/null || true; \
		fi; \
	}; \
	wait_for_port() { \
		local host="$$1" port="$$2" attempt; \
		for attempt in $$(seq 1 100); do \
			if (exec 3<>"/dev/tcp/$$host/$$port") 2>/dev/null; then \
				exec 3>&-; \
				exec 3<&-; \
				return 0; \
			fi; \
			sleep 0.1; \
		done; \
		echo "Timed out waiting for $$host:$$port" >&2; \
		return 1; \
	}; \
	trap cleanup EXIT INT TERM; \
	for script in $(AVAILABLE_SERVER_SCRIPTS); do \
		echo "[server] $$script"; \
		$(RUBY_RUN) "$$script" & \
		pids+=("$$!"); \
	done; \
	for port in $(AVAILABLE_PORTS); do \
		wait_for_port 127.0.0.1 "$$port"; \
	done; \
	sleep 0.2; \
	$(MAKE) --no-print-directory examples

full-demo: check-dependencies
	@$(MAKE) --no-print-directory demo

# Runs every pair that only needs Ruby's standard library (plus WEBrick).
standard-demo:
	@$(MAKE) --no-print-directory demo DISABLE_OPTIONAL=1

grpc-python-setup:
	@$(PYTHON) -m venv .venv-grpc
	@.venv-grpc/bin/python -m pip install -r examples/servers/requirements-grpc.txt
	@$(MAKE) --no-print-directory grpc-python-generate PYTHON_GRPC=.venv-grpc/bin/python

grpc-python-generate: check-python-grpc-tools
	@mkdir -p examples/generated
	@$(PYTHON_GRPC) -m grpc_tools.protoc \
		-I proto \
		--python_out=examples/generated \
		--grpc_python_out=examples/generated \
		proto/utcp.proto

grpc-python-server: check-python-grpc
	@PORT="$(PYTHON_GRPC_PORT)" $(PYTHON_GRPC) examples/servers/grpc_server.py

grpc-python-client: check-python-grpc
	@UTCP_GRPC_PORT="$(PYTHON_GRPC_PORT)" $(PYTHON_GRPC) examples/grpc_python.py

grpc-python-demo: check-python-grpc check-ruby-grpc
	@set -euo pipefail; \
	if (exec 3<>"/dev/tcp/127.0.0.1/$(PYTHON_GRPC_PORT)") 2>/dev/null; then \
		exec 3>&-; exec 3<&-; \
		echo "Port $(PYTHON_GRPC_PORT) is already in use." >&2; \
		exit 1; \
	fi; \
	server_pid=""; \
	cleanup() { \
		if [[ -n "$$server_pid" ]]; then \
			kill "$$server_pid" 2>/dev/null || true; \
			wait "$$server_pid" 2>/dev/null || true; \
		fi; \
	}; \
	trap cleanup EXIT INT TERM; \
	PORT="$(PYTHON_GRPC_PORT)" $(PYTHON_GRPC) examples/servers/grpc_server.py & \
	server_pid="$$!"; \
	ready=0; \
	for attempt in $$(seq 1 100); do \
		if (exec 3<>"/dev/tcp/127.0.0.1/$(PYTHON_GRPC_PORT)") 2>/dev/null; then \
			exec 3>&-; exec 3<&-; ready=1; break; \
		fi; \
		if ! kill -0 "$$server_pid" 2>/dev/null; then \
			wait "$$server_pid"; exit 1; \
		fi; \
		sleep 0.1; \
	done; \
	if [[ "$$ready" != "1" ]]; then \
		echo "Timed out waiting for Python gRPC server." >&2; exit 1; \
	fi; \
	UTCP_GRPC_PORT="$(PYTHON_GRPC_PORT)" $(RUBY_RUN) examples/grpc.rb; \
	UTCP_GRPC_PORT="$(PYTHON_GRPC_PORT)" $(PYTHON_GRPC) examples/grpc_python.py

test:
	$(RUBY_RUN) -S rake test
