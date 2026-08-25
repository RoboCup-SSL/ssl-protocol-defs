PROTO_DIR := proto
PROTOS := $(shell find $(PROTO_DIR) -name '*.proto')

.PHONY: compile-protos
compile-protos:
	protoc --proto_path=$(PROTO_DIR) --descriptor_set_out=/dev/null $(PROTOS)

# Generated bindings for local inspection; consuming projects normally invoke
# python/python_bindings.py from their own build instead.
PYTHON_BINDINGS_OUT ?= gen
PYTHON_BINDINGS_PACKAGE ?= sslproto

.PHONY: python-bindings
python-bindings:
	python3 python/python_bindings.py \
		--out-dir $(PYTHON_BINDINGS_OUT) --package $(PYTHON_BINDINGS_PACKAGE)

.PHONY: test-wireshark-dissectors
test-wireshark-dissectors:
	python3 wireshark/tests/run_tests.py

.PHONY: check-wireshark-dependencies
check-wireshark-dependencies:
	@wireshark/setup.sh check

.PHONY: install-wireshark-dissectors
install-wireshark-dissectors:
	@wireshark/setup.sh install

.PHONY: uninstall-wireshark-dissectors
uninstall-wireshark-dissectors:
	@wireshark/setup.sh uninstall
