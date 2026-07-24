PROTO_DIR := proto
PROTOS := $(shell find $(PROTO_DIR) -name '*.proto')

.PHONY: compile-protos
compile-protos:
	protoc --proto_path=$(PROTO_DIR) --descriptor_set_out=/dev/null $(PROTOS)

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
