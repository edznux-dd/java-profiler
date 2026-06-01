/*
 * Copyright 2026, Datadog, Inc.
 * SPDX-License-Identifier: Apache-2.0
 *
 * libFuzzer fuzz target for the legacy Rust symbol demangler.
 *
 * RustDemangler turns mangled Rust symbol names into readable form. In
 * production (flightRecorder.cpp) the input is the output of the C++ ABI
 * demangler for a native frame, i.e. an attacker-influenced symbol name read
 * out of a loaded binary. The flow is always:
 *
 *     if (RustDemangler::is_probably_rust_legacy(s))
 *         RustDemangler::demangle(s);
 *
 * This harness preserves that ordering so it only exercises states reachable in
 * production. demangle() does pointer-relative reads (e.g. the leading "_$"
 * special case, the "$u00$" unicode escape that peeks four bytes ahead, and the
 * fixed-size pattern table) and sizes its output buffer with
 * `str.size() - hash_pre - hash_eg`, an unsigned subtraction that underflows if
 * demangle() is ever reached for a string shorter than the hash suffix.
 *
 * Expected bug classes:
 * - Out-of-bounds reads in the $-escape / unicode-escape scanning
 * - Unsigned-underflow / over-allocation on short or malformed inputs
 * - Mismatches between the is_probably_rust_legacy() guard and demangle()'s
 *   own size assumptions
 */

#include <stddef.h>
#include <stdint.h>
#include <string>

#include "rustDemangler.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    // Cap to keep iterations cheap; real symbol names are far shorter.
    if (size > 64 * 1024) {
        size = 64 * 1024;
    }

    std::string input(reinterpret_cast<const char *>(data), size);

    // Mirror the production guard ordering exactly: demangle() documents that it
    // must only be called on strings the predicate has already accepted.
    if (RustDemangler::is_probably_rust_legacy(input)) {
        std::string out = RustDemangler::demangle(input);
        (void)out;
    }

    return 0;
}
