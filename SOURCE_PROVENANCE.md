# Source provenance

This repository packages the Gator++ ARM64 Docker stack and its modified Judge0 application together. A normal clone includes the complete build input; there are no submodules or separate private source repositories to retrieve.

The application in `judge0-src/` was exported from local Judge0 fork commit `cc32d7ddcfba1a04c22f736be50f18a56870d261` ("Precompile the C++ standard headers the submissions actually include"). Its upstream is https://github.com/judge0/judge0, version 1.13.1. The export contains tracked source files only, without the nested Git database or runtime files. The original local fork remains separate and unchanged.

The outer repository retains the ARM64 stack's development history. `OPTIMIZATION_REPORT.md` and `benchmarks/` describe historical measurements from that development environment. This distribution explicitly starts two worker processes and caps the queue at 20; historical benchmark concurrency numbers are not a promise about this profile.

Judge0 and this derivative are GPL-3.0. License texts are included at `LICENSE` and `judge0-src/LICENSE`. Isolate is downloaded and compiled by `Dockerfile.arm64` from https://github.com/ioi/isolate during the image build; its revision is not pinned. Changes upstream can therefore affect a later rebuild.

Maintain application changes directly in `judge0-src/`, and include them in the same repository commit as corresponding Docker, checks, or documentation changes. Keep the language seed and installed toolchains aligned. Never replace this directory with an unmodified upstream checkout: the ARM64 runtime and optimization changes are part of the current implementation.
