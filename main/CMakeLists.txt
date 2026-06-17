# Embedded Swift Firmata port <-> ESP-IDF + arduino-esp32 component.
# Protocol/scheduler/logic = Main.swift (compiled with the custom Xtensa swiftc),
# Arduino hardware + Wi-Fi/Bonjour transport = firmata_shim.cpp.

idf_component_register(
    SRCS "firmata_shim.cpp" "atomic_stubs.c"
    PRIV_INCLUDE_DIRS "."
    REQUIRES espressif__arduino-esp32
)

idf_build_get_property(target IDF_TARGET)
idf_build_get_property(arch   IDF_TARGET_ARCH)
if(NOT "${arch}" STREQUAL "xtensa")
    message(FATAL_ERROR "This project targets Xtensa ESP32 parts; got ${target} (${arch}).")
endif()
if("${target}" STREQUAL "esp32")
    set(SWIFT_TARGET_TRIPLE "xtensa-esp32-none-elf")
elseif("${target}" STREQUAL "esp32s2")
    set(SWIFT_TARGET_TRIPLE "xtensa-esp32s2-none-elf")
elseif("${target}" STREQUAL "esp32s3")
    set(SWIFT_TARGET_TRIPLE "xtensa-esp32s3-none-elf")
else()
    message(FATAL_ERROR "Unsupported Xtensa target: ${target}")
endif()

set(SWIFTC "${CMAKE_CURRENT_SOURCE_DIR}/../../install/bin/swiftc")
if(NOT EXISTS "${SWIFTC}")
    message(FATAL_ERROR "Custom Swift compiler not found at:\n  ${SWIFTC}")
endif()
message(STATUS "Embedded Swift Firmata port: ${SWIFTC}  ->  ${SWIFT_TARGET_TRIPLE}")

set(SWIFT_OBJ "${CMAKE_CURRENT_BINARY_DIR}/Main.swift.o")
add_custom_command(
    OUTPUT  "${SWIFT_OBJ}"
    COMMAND "${SWIFTC}"
            -target ${SWIFT_TARGET_TRIPLE}
            -module-name firmata
            -enable-experimental-feature Embedded
            -wmo -parse-as-library -Osize
            -Xfrontend -function-sections
            -Xcc -fno-pic -Xcc -fno-pie
            -import-objc-header "${CMAKE_CURRENT_SOURCE_DIR}/BridgingHeader.h"
            -c "${CMAKE_CURRENT_SOURCE_DIR}/Main.swift"
            -o "${SWIFT_OBJ}"
    DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/Main.swift"
            "${CMAKE_CURRENT_SOURCE_DIR}/BridgingHeader.h"
    COMMENT "Compiling Main.swift -> ${SWIFT_TARGET_TRIPLE} (Embedded Swift Firmata)"
    VERBATIM)

set_source_files_properties("${SWIFT_OBJ}" PROPERTIES EXTERNAL_OBJECT TRUE GENERATED TRUE)
target_sources(${COMPONENT_LIB} PRIVATE "${SWIFT_OBJ}")

add_custom_command(TARGET ${COMPONENT_LIB} POST_BUILD
    COMMAND ${CMAKE_OBJCOPY} --remove-section .swift_modhash
            $<TARGET_FILE:${COMPONENT_LIB}> $<TARGET_FILE:${COMPONENT_LIB}> || true)

# Discard Swift metadata sections not used at runtime.
target_link_options(${COMPONENT_LIB} INTERFACE "-T" "${CMAKE_CURRENT_SOURCE_DIR}/swift_sections.ld")
