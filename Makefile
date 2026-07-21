PROTO_DIR := proto
PROTOS := $(shell find $(PROTO_DIR) -name '*.proto')

.PHONY: check
check:
	protoc --proto_path=$(PROTO_DIR) --descriptor_set_out=/dev/null $(PROTOS)
