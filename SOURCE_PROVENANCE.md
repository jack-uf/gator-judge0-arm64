# Source provenance

This repository packages the Gator++ ARM64 Docker stack and its modified Judge0 application together. A normal clone includes the complete build input; there are no submodules or separate private source repositories to retrieve.

The application in `judge0-src/` was exported from local Judge0 fork commit `cc32d7ddcfba1a04c22f736be50f18a56870d261` ("Precompile the C++ standard headers the submissions actually include"). Its upstream is https://github.com/judge0/judge0, version 1.13.1. The export contains tracked source files only, without the nested Git database or runtime files. The original local fork remains separate and unchanged.

This distribution starts two worker processes and caps the queue at 20. Development history, including earlier benchmark scripts and measurements, remains available in Git history.

Judge0 and this derivative are GPL-3.0. License texts are included at `LICENSE` and `judge0-src/LICENSE`. Isolate is downloaded and compiled by `Dockerfile.arm64` from https://github.com/ioi/isolate at commit `8f185bb37f3f23e29b33b0c7727c91c13429abe3`. Updating that commit requires an explicit Dockerfile change. Ubuntu packages and image tags remain moving dependencies.

The export is the starting point, not a frozen copy. Changes after the export are recorded in this repository's Git history. On October 12, 2026, the launch scripts were changed to keep configuration values out of service logs, a worker readiness check was added, and the language seed was aligned with the native compiler paths and versions. The application itself remains licensed under GPL-3.0. This distribution is a community derivative, not an official Judge0 release.

Maintain application changes directly in `judge0-src/`, and include them in the same repository commit as corresponding Docker, checks, or documentation changes. Keep the language seed and installed toolchains aligned. Never replace this directory with an unmodified upstream checkout: the ARM64 runtime and optimization changes are part of the current implementation.
