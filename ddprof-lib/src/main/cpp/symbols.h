/*
 * Copyright The async-profiler authors
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef _SYMBOLS_H
#define _SYMBOLS_H

#include "codeCache.h"
#include "mutex.h"

#include <stdint.h>


class Symbols {
  private:
    static Mutex _parse_lock;
    static bool _have_kernel_symbols;
    static bool _libs_limit_reported;

  public:
    static void initLibraryRanges();
    static void parseKernelSymbols(CodeCache* cc);
    static void parseLibraries(CodeCacheArray* array, bool kernel_symbols);

    static bool haveKernelSymbols() {
        return _have_kernel_symbols;
    }
    // Clear internal caches - mainly for test purposes
    static void clearParsingCaches();
    // Fast range check: does this PC lie in libc or libpthread?
    static bool isLibcOrPthreadAddress(uintptr_t pc);

#ifdef FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION
    // Fuzz-only entry point exposing the otherwise file-internal ELF symbol
    // parser (ElfParser::parseFile) so a libFuzzer harness can drive it against
    // an arbitrary on-disk ELF image. Not compiled into production builds.
    static bool parseElfFileForFuzzing(CodeCache* cc, const char* file_name, bool use_debug);
#endif
};

class UnloadProtection {
  private:
    void* _lib_handle;
    bool _valid;

  public:
    UnloadProtection(const CodeCache *cc);
    ~UnloadProtection();

    UnloadProtection& operator=(const UnloadProtection& other) = delete;

    bool isValid() const { return _valid; }
};

#endif // _SYMBOLS_H
