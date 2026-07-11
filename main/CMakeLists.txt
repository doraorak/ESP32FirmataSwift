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

# Locate the custom Xtensa Embedded-Swift toolchain (install/ in the workspace).
# Robust to where this project sits in the tree; override -DSWIFTC=... if needed.
set(SWIFTC "")
foreach(cand
        "${CMAKE_CURRENT_SOURCE_DIR}/../../../install/bin/swiftc"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../install/bin/swiftc"
        "$ENV{HOME}/Desktop/swift-xtensa-esp32/install/bin/swiftc")
    if(EXISTS "${cand}")
        set(SWIFTC "${cand}")
        break()
    endif()
endforeach()
if(SWIFTC STREQUAL "")
    message(FATAL_ERROR "Custom Swift (Xtensa) compiler not found; pass -DSWIFTC=/path/to/install/bin/swiftc")
endif()
message(STATUS "Embedded Swift Firmata port: ${SWIFTC}  ->  ${SWIFT_TARGET_TRIPLE}")

# Embedded Swift firmware sources. Compiled together as a single module (-wmo),
# so declaration order between files is irrelevant. Keep this list in sync with
# the .swift files in this directory.
set(SWIFT_SRCS
    "${CMAKE_CURRENT_SOURCE_DIR}/FirmataProtocol.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/RuntimeState.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/Messaging.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/LiveProtocol.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/Encoder7Bit.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/Scheduler.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/Modules.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/IRModule.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/SonarModule.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/DHTModule.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/DisplayModule.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/Session.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/Configuration.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/Transport.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/Main.swift")

set(SWIFT_OBJ "${CMAKE_CURRENT_BINARY_DIR}/firmata.swift.o")
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
            -c ${SWIFT_SRCS}
            -o "${SWIFT_OBJ}"
    DEPENDS ${SWIFT_SRCS}
            "${CMAKE_CURRENT_SOURCE_DIR}/BridgingHeader.h"
    COMMENT "Compiling Embedded Swift Firmata (${SWIFT_TARGET_TRIPLE})"
    VERBATIM)

set_source_files_properties("${SWIFT_OBJ}" PROPERTIES EXTERNAL_OBJECT TRUE GENERATED TRUE)
target_sources(${COMPONENT_LIB} PRIVATE "${SWIFT_OBJ}")

add_custom_command(TARGET ${COMPONENT_LIB} POST_BUILD
    COMMAND ${CMAKE_OBJCOPY} --remove-section .swift_modhash
            $<TARGET_FILE:${COMPONENT_LIB}> $<TARGET_FILE:${COMPONENT_LIB}> || true)

# Discard Swift metadata sections not used at runtime.
target_link_options(${COMPONENT_LIB} INTERFACE "-T" "${CMAKE_CURRENT_SOURCE_DIR}/swift_sections.ld")
