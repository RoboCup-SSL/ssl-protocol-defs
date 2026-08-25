# Generate C++ bindings from the SSL protocol definitions.
#
# Usage from a project that vendors this repository as a git submodule:
#
#   list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/<submodule>/cmake")
#   include(SSLProtocolDefs)
#
#   ssl_protocol_defs_generate_cpp(
#           OUT_DIR "${CMAKE_SOURCE_DIR}/src/sslproto"
#           PROTOS vision/ssl_vision_wrapper.proto gamecontroller/ssl_gc_referee_message.proto
#           SOURCES_VAR PROTO_SRCS
#           HEADERS_VAR PROTO_HDRS)
#
#   add_custom_target(GENERATE_PROTOS DEPENDS ${PROTO_SRCS} ${PROTO_HDRS})
#   target_sources(my_target PRIVATE ${PROTO_SRCS})
#   add_dependencies(my_target GENERATE_PROTOS)
#
# CMake's own protobuf_generate() is deliberately not used here: it seeds protoc
# with -I${CMAKE_CURRENT_SOURCE_DIR} and derives the output subdirectory from
# the proto's path relative to *that*, ignoring IMPORT_DIRS. For a submodule
# that buries the generated files under a copy of the submodule path. Calling
# protoc directly keeps the output layout predictable.
#
# IMPORTANT -- include paths. Every import in this repository is written
# relative to proto/, so protoc bakes sibling includes of the same shape into
# the generated headers ("vision/x.pb.h" includes "gamecontroller/y.pb.h").
# OUT_DIR must therefore be on the include path:
#
#   include_directories("${CMAKE_SOURCE_DIR}/src/sslproto")   # sibling includes
#   include_directories("${CMAKE_SOURCE_DIR}/src")            # your own prefix
#
# With both, your code includes "sslproto/vision/ssl_vision_wrapper.pb.h" while
# the generated headers resolve each other. Choose OUT_DIR's name to be the
# prefix you want to write; nesting it one level below an existing include root
# is what keeps the protocol headers distinguishable from your own sources.

if(NOT DEFINED SSL_PROTOCOL_DEFS_PROTO_ROOT)
    get_filename_component(_ssl_protocol_defs_root "${CMAKE_CURRENT_LIST_DIR}" DIRECTORY)
    set(SSL_PROTOCOL_DEFS_PROTO_ROOT "${_ssl_protocol_defs_root}/proto"
            CACHE PATH "protoc include root for the SSL protocol definitions")
    unset(_ssl_protocol_defs_root)
endif()

# ssl_protocol_defs_generate_cpp(PROTOS <rel>... [OUT_DIR <dir>] [PROTO_ROOT <dir>]
#                                [SOURCES_VAR <var>] [HEADERS_VAR <var>])
#
# PROTOS are paths relative to PROTO_ROOT; protoc mirrors them below OUT_DIR.
# OUT_DIR defaults to ${CMAKE_CURRENT_BINARY_DIR}, which is what you want for a
# normal out-of-source build; pass it explicitly to generate into the source
# tree instead. SOURCES_VAR / HEADERS_VAR receive the generated .pb.cc / .pb.h
# paths in the caller's scope.
function(ssl_protocol_defs_generate_cpp)
    cmake_parse_arguments(ARG "" "OUT_DIR;PROTO_ROOT;SOURCES_VAR;HEADERS_VAR" "PROTOS" ${ARGN})

    if(NOT ARG_OUT_DIR)
        set(ARG_OUT_DIR "${CMAKE_CURRENT_BINARY_DIR}")
    endif()
    if(NOT ARG_PROTOS)
        message(FATAL_ERROR "ssl_protocol_defs_generate_cpp: PROTOS is required")
    endif()
    if(ARG_UNPARSED_ARGUMENTS)
        message(FATAL_ERROR
                "ssl_protocol_defs_generate_cpp: unexpected arguments: ${ARG_UNPARSED_ARGUMENTS}")
    endif()
    if(NOT ARG_PROTO_ROOT)
        set(ARG_PROTO_ROOT "${SSL_PROTOCOL_DEFS_PROTO_ROOT}")
    endif()

    if(NOT EXISTS "${ARG_PROTO_ROOT}")
        message(FATAL_ERROR
                "SSL protocol definitions not found at ${ARG_PROTO_ROOT}. If this is a git "
                "submodule, run: git submodule update --init --recursive")
    endif()

    # Prefer the imported target so the build re-runs when protoc itself changes.
    if(TARGET protobuf::protoc)
        set(_protoc protobuf::protoc)
    elseif(Protobuf_PROTOC_EXECUTABLE)
        set(_protoc "${Protobuf_PROTOC_EXECUTABLE}")
    else()
        message(FATAL_ERROR
                "ssl_protocol_defs_generate_cpp: protoc not found. Call find_package(Protobuf) "
                "before this function.")
    endif()

    set(_srcs "")
    set(_hdrs "")
    set(_inputs "")
    foreach(proto_file IN LISTS ARG_PROTOS)
        if(NOT EXISTS "${ARG_PROTO_ROOT}/${proto_file}")
            message(FATAL_ERROR
                    "ssl_protocol_defs_generate_cpp: no such proto: ${ARG_PROTO_ROOT}/${proto_file}")
        endif()
        string(REGEX REPLACE "\\.proto$" "" proto_stem "${proto_file}")
        list(APPEND _inputs "${ARG_PROTO_ROOT}/${proto_file}")
        list(APPEND _srcs "${ARG_OUT_DIR}/${proto_stem}.pb.cc")
        list(APPEND _hdrs "${ARG_OUT_DIR}/${proto_stem}.pb.h")
    endforeach()

    add_custom_command(
            OUTPUT ${_srcs} ${_hdrs}
            # protoc will not create a missing --cpp_out directory.
            COMMAND ${CMAKE_COMMAND} -E make_directory "${ARG_OUT_DIR}"
            COMMAND ${_protoc} "--proto_path=${ARG_PROTO_ROOT}" "--cpp_out=${ARG_OUT_DIR}" ${ARG_PROTOS}
            DEPENDS ${_inputs} ${_protoc}
            COMMENT "Generating SSL protocol C++ bindings"
            VERBATIM
    )

    # add_custom_command() marks its OUTPUTs GENERATED only in the directory
    # scope it is called from. Setting the property explicitly keeps the
    # generated files usable when the caller consumes them from another scope.
    set_source_files_properties(${_srcs} ${_hdrs} PROPERTIES GENERATED TRUE)

    if(ARG_SOURCES_VAR)
        set(${ARG_SOURCES_VAR} ${_srcs} PARENT_SCOPE)
    endif()
    if(ARG_HEADERS_VAR)
        set(${ARG_HEADERS_VAR} ${_hdrs} PARENT_SCOPE)
    endif()
endfunction()
