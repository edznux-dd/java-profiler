/*
 * Gradle build file for libFuzzer-based fuzz testing.
 * This module compiles and runs fuzz targets against the profiler's C++ code
 * to discover bugs through automated input generation.
 */

plugins {
  base
  id("com.datadoghq.fuzz-targets")
}

fuzzTargets {
  // Source directory containing fuzz target files (fuzz_*.cpp)
  fuzzSourceDir.set(project(":ddprof-lib").file("src/test/fuzz"))

  // Seed corpus directory for each target (subdirectories named by target)
  corpusDir.set(project(":ddprof-lib").file("src/test/fuzz/corpus"))

  // Main profiler sources to compile with fuzz targets
  profilerSourceDir.set(project(":ddprof-lib").file("src/main/cpp"))

  // Additional include directories
  additionalIncludes.set(
    listOf(
      project(":malloc-shim").file("src/main/public").absolutePath,
    ),
  )
}

// Source-based code-coverage report for the fuzz harnesses.
//
//   ./gradlew :ddprof-lib:fuzz:fuzzCoverage                       # replay existing corpus (fast)
//   ./gradlew :ddprof-lib:fuzz:fuzzCoverage -Pfuzz-cov-duration=45 # fuzz 45s/target first, then measure
//
// Builds every fuzz_*.cpp with clang coverage instrumentation, replays (or
// fuzzes) each corpus, and emits an llvm-cov summary plus browsable HTML at
// ddprof-lib/fuzz/build/coverage/html/index.html.
tasks.register<Exec>("fuzzCoverage") {
  group = "verification"
  description = "Generate a code-coverage report for the fuzz harnesses (llvm-cov)"

  val duration = if (project.hasProperty("fuzz-cov-duration")) {
    project.property("fuzz-cov-duration").toString()
  } else {
    "0"
  }
  val script = project(":ddprof-lib").file("src/test/fuzz/coverage.sh")

  // JAVA_HOME is required by the script for the JNI includes.
  environment("JAVA_HOME", System.getenv("JAVA_HOME") ?: org.gradle.internal.jvm.Jvm.current().javaHome.absolutePath)
  commandLine("bash", script.absolutePath, duration)
}
