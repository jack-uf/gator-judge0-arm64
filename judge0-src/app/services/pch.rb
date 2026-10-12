# Precompiled headers for the C++ compile path.
# Modified for Gator++ on 2026-10-12: document the current native build.
#
# `Dockerfile.arm64` builds `iostream.gch` at image-build time and writes a
# SHA256 manifest next to it. Every C++ compile then gets that directory on its
# include path, so `#include <iostream>` -- and the whole `<ostream>` family it
# pulls in -- is read from the precompiled form instead of being parsed again
# for every submission. The compiler and flags must match those used by the
# Dockerfile when building the header.
#
# The gate below is what makes the optimisation safe to ship:
#
#   * The PCH is only offered when a manifest entry matches the file on disk, so
#     a missing, empty, truncated or non-matching `.gch` degrades to the
#     ordinary header parse. Compiling a header with a corrupt PCH is a *hard*
#     compiler error (`rc=1`), which would be reported to the student as their
#     own mistake, so the check has to happen before the flag is passed rather
#     than after a failed attempt.
#   * Flag mismatches do not need this gate: GCC silently ignores a PCH built
#     with a different `-O` level, standard or feature flags and rebuilds the
#     headers the usual way. Only a damaged file is dangerous.
#
# The result is memoised per process -- verifying means reading the whole PCH.
# The file lives in the image layer and is root-owned, so the only supported way
# to change it is rebuilding the image, which restarts this process: recovery
# from a suspect PCH is `docker compose up -d --build worker`, and the fast way
# to disable it without a rebuild is to delete the manifest, which turns the
# gate off for every process that starts afterwards.
require "digest"

module Pch
  # Root-owned and world-readable, which is also what makes it read-only for a
  # submission: Isolate mounts the host root read-only, so a sandbox can read
  # this PCH and can never write to it.
  DIR = "/usr/local/pch/c++".freeze
  MANIFEST = "pch.sha256".freeze
  SHA256_HEX = /\A[0-9a-f]{64}\z/.freeze

  class << self
    # The include path argument for a C++ compile, or an empty list when there
    # is no verified PCH to offer. Returning a list keeps the call site free of
    # conditionals and leaves room for more than one PCH directory later.
    def include_args(dir = DIR)
      usable?(dir) ? ["-I#{dir}"] : []
    end

    # Identity of the PCH set for the compilation-cache key. Two workers that
    # have different PCHs installed must not share cached binaries, and a
    # rebuilt PCH must invalidate entries even when the compiler binary it was
    # built from is byte-identical -- which is exactly the case a PCH change
    # creates, and the one `CompilationCache.toolchain_fingerprint` cannot see.
    def fingerprint(dir = DIR)
      return "pch:none" unless usable?(dir)
      "pch:#{Digest::SHA256.hexdigest(File.read(File.join(dir, MANIFEST)))}"
    end

    # True when a manifest exists, lists at least one entry, and every entry
    # matches the file it names. Any doubt -- no manifest, unreadable file,
    # short read, digest mismatch -- answers false, which costs milliseconds of
    # header parsing and never changes a verdict.
    def usable?(dir = DIR)
      @usable ||= {}
      @usable.fetch(dir) { @usable[dir] = manifest_verifies?(dir) }
    end

    private

    def manifest_verifies?(dir)
      entries = File.readlines(File.join(dir, MANIFEST)).map(&:strip).reject(&:empty?)
      !entries.empty? && entries.all? { |entry| entry_verifies?(dir, entry) }
    rescue SystemCallError, IOError
      false
    end

    def entry_verifies?(dir, entry)
      digest, name = entry.split(/\s+/, 2)
      # `sha256sum` prefixes a mode marker in binary mode; both forms appear in
      # the wild, so the marker is stripped rather than rejected.
      name = name.to_s.sub(/\A[*\\]/, "")
      return false unless digest.to_s.match?(SHA256_HEX)
      return false if name.empty? || name.include?("/")
      path = File.join(dir, name)
      File.file?(path) && Digest::SHA256.file(path).hexdigest == digest
    end
  end
end
