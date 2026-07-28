DART ?= dart
APP := build/context-propagation-lab

.PHONY: run json format analyze test server-test build check clean

run:
	$(DART) run bin/server.dart

json:
	$(DART) run bin/server.dart --json

format:
	$(DART) format --output=none --set-exit-if-changed bin lib test

analyze:
	$(DART) analyze

test:
	$(DART) run test/model_test.dart
	$(DART) run test/runtime_context_test.dart

server-test:
	sh tests/server_test.sh

build:
	mkdir -p build
	$(DART) compile exe bin/server.dart -o $(APP)

check: format analyze test server-test build
	$(APP) --json | grep -q '"zone_plus_envelope"'

clean:
	rm -f $(APP)
