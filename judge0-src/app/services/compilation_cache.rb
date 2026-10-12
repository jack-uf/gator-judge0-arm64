require 'digest'
require 'fileutils'
require 'json'

module CompilationCache
  CACHE_DIR = ENV["COMPILATION_CACHE_DIR"].presence || Rails.root.join("tmp", "cache", "binaries").to_s
  MAX_CACHE_BYTES = 500 * 1024 * 1024 # 500 MB bounded cache
  # Identifies the Gator++ harness/runtime shipped alongside the student source.
  # Bump it when the harness headers or the prebuilt runtime change; the image
  # can also set it so two deployments never share entries.
  RUNTIME_VERSION = ENV["GATOR_RUNTIME_VERSION"].presence || "gator_runtime_v1"

  def self.cache_key(submission, effective_compiler_options = nil)
    return nil if submission.is_project || submission.source_code.blank?
    opts = effective_compiler_options || submission.compiler_options.to_s
    Digest::SHA256.hexdigest([
      submission.source_code,
      "aarch64",
      submission.language_id.to_s,
      submission.language&.compile_cmd.to_s,
      opts,
      # Extra files (key.h) are compiled into the binary just as much as the
      # source is. Without this, editing a lesson's header keeps serving the
      # binary built against the previous one.
      Digest::SHA256.hexdigest(submission.additional_files.to_s),
      RUNTIME_VERSION,
      # The toolchain itself. Every other component describes the *request*; if
      # the compiler is replaced by a different build that accepts or codegens
      # the same source differently, a key made only of request fields keeps
      # serving the old binary. Statting the executable is free and changes
      # whenever the image changes.
      toolchain_fingerprint(submission.language&.compile_cmd),
      # The PCH is built from that same compiler, but it can be rebuilt on its
      # own: a header added to the PCH set changes what the compiler reads
      # without changing the compiler binary, and the toolchain fingerprint
      # above would not notice. Keying on the PCH's own content closes that gap.
      Pch.fingerprint
    ].join("::"))
  end

  # Size and mtime of the compiler the language definition invokes. Falls back to
  # a constant when the path is not resolvable in this process, which is the
  # safe direction: it can only produce a key that is too coarse, never one that
  # mixes two toolchains.
  def self.toolchain_fingerprint(compile_cmd)
    # Read through the same parser the worker compiles with, so a leading
    # `VAR=value` assignment (the GCC toolchain definitions carry
    # LD_LIBRARY_PATH that way) fingerprints the compiler rather than the
    # assignment, which would stat nothing and flatten every entry for that
    # language onto one constant key.
    compiler = ExecPlan.parse(compile_cmd)&.dig(:argv, 0) || compile_cmd.to_s.split(" ").first
    return "unknown" if compiler.blank?
    stat = File.stat(compiler)
    "#{compiler}:#{stat.size}:#{stat.mtime.to_i}"
  rescue SystemCallError
    "unknown:#{compiler}"
  end

  def self.lookup(cache_key)
    return nil unless cache_key
    entry_dir = File.join(CACHE_DIR, cache_key)
    meta_path = File.join(entry_dir, "meta.json")
    return nil unless File.exist?(meta_path)

    meta = JSON.parse(File.read(meta_path)) rescue {}

    # A recorded compile failure has no binary to serve. Students retry the same
    # broken source constantly, and the compiler will produce the same
    # diagnostics every time, so the diagnostics are what gets cached.
    if meta["failed"]
      return { failed: true, compile_output: read_compile_output(entry_dir) }
    end

    binary_name = meta["binary_name"] || "a.out"
    binary_path = File.join(entry_dir, binary_name)
    return nil unless File.exist?(binary_path) && File.size(binary_path) > 0

    # Update access time for LRU tracking
    FileUtils.touch(meta_path) rescue nil

    {
      binary_path: binary_path,
      binary_name: binary_name,
      compile_output: read_compile_output(entry_dir)
    }
  rescue Exception => e
    Rails.logger.warn("CompilationCache.lookup error for #{cache_key}: #{e.message}")
    nil
  end

  def self.read_compile_output(entry_dir)
    path = File.join(entry_dir, "compile_output.txt")
    return nil unless File.exist?(path)
    output = File.read(path)
    output.empty? ? nil : output
  end

  # Caches a compile that produced diagnostics instead of a binary. Only
  # deterministic outcomes belong here: a nonzero compiler exit is reproducible
  # from the same source and flags, a timeout is not, so callers must filter.
  def self.store_failure(cache_key, compile_output)
    return unless cache_key

    FileUtils.mkdir_p(CACHE_DIR)
    entry_dir = File.join(CACHE_DIR, cache_key)
    tmp_entry = "#{entry_dir}.tmp.#{Process.pid}"
    FileUtils.mkdir_p(tmp_entry)

    File.write(File.join(tmp_entry, "compile_output.txt"), compile_output.to_s)
    File.write(File.join(tmp_entry, "meta.json"), JSON.generate({
      "failed" => true,
      "created_at" => Time.now.to_i
    }))

    FileUtils.rm_rf(entry_dir) if Dir.exist?(entry_dir)
    FileUtils.mv(tmp_entry, entry_dir)

    prune_if_needed
  rescue Exception => e
    Rails.logger.warn("CompilationCache.store_failure error for #{cache_key}: #{e.message}")
  end

  def self.store(cache_key, binary_src_path, compile_output = nil, binary_name = "a.out")
    return unless cache_key && File.exist?(binary_src_path) && File.size(binary_src_path) > 0

    FileUtils.mkdir_p(CACHE_DIR)
    entry_dir = File.join(CACHE_DIR, cache_key)
    tmp_entry = "#{entry_dir}.tmp.#{Process.pid}"
    FileUtils.mkdir_p(tmp_entry)

    dest_binary = File.join(tmp_entry, binary_name)
    FileUtils.cp(binary_src_path, dest_binary)
    File.chmod(0755, dest_binary)

    if compile_output.present?
      File.write(File.join(tmp_entry, "compile_output.txt"), compile_output)
    end

    File.write(File.join(tmp_entry, "meta.json"), JSON.generate({
      "binary_name" => binary_name,
      "created_at" => Time.now.to_i,
      "size" => File.size(binary_src_path)
    }))

    FileUtils.rm_rf(entry_dir) if Dir.exist?(entry_dir)
    FileUtils.mv(tmp_entry, entry_dir)

    prune_if_needed
  rescue Exception => e
    Rails.logger.warn("CompilationCache.store error for #{cache_key}: #{e.message}")
  end

  def self.prune_if_needed
    return unless Dir.exist?(CACHE_DIR)
    entries = Dir.glob(File.join(CACHE_DIR, "*")).select { |f| Dir.exist?(f) }
    total_size = entries.sum { |d| Dir.glob(File.join(d, "*")).sum { |f| File.size(f) rescue 0 } }
    return if total_size <= MAX_CACHE_BYTES

    sorted = entries.sort_by { |d| File.mtime(d) rescue Time.at(0) }
    while total_size > (MAX_CACHE_BYTES * 0.8) && sorted.any?
      oldest = sorted.shift
      old_size = Dir.glob(File.join(oldest, "*")).sum { |f| File.size(f) rescue 0 }
      FileUtils.rm_rf(oldest)
      total_size -= old_size
    end
  rescue Exception => e
    Rails.logger.warn("CompilationCache.prune error: #{e.message}")
  end
end
