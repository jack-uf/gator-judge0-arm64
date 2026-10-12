require "shellwords"

class IsolateJob < ApplicationJob
  retry_on RuntimeError, wait: 0.1.seconds, attempts: 100

  queue_as ENV["JUDGE0_VERSION"].to_sym

  STDIN_FILE_NAME = "stdin.txt"
  STDOUT_FILE_NAME = "stdout.txt"
  STDERR_FILE_NAME = "stderr.txt"
  METADATA_FILE_NAME = "metadata.txt"
  ADDITIONAL_FILES_ARCHIVE_FILE_NAME = "additional_files.zip"

  # Marker that distinguishes a packed per-test stdin payload (written by the
  # controller) from an ordinary single-stdin submission. Public because both
  # the controller and Submission#test_count have to recognise it.
  TESTS_PAYLOAD_KEY = "__gator_tests__".freeze

  def self.tests_payload(stdin)
    return nil if stdin.blank? || !stdin.start_with?("{\"#{TESTS_PAYLOAD_KEY}\":")
    parsed = JSON.parse(stdin) rescue nil
    tests = parsed && parsed[TESTS_PAYLOAD_KEY]
    tests.is_a?(Array) ? tests : nil
  end

  attr_reader :submission, :cgroups,
              :box_id, :workdir, :boxdir, :tmpdir,
              :source_file, :stdin_file, :stdout_file,
              :stderr_file, :metadata_file, :additional_files_archive_file

  def perform(submission_id)
    @submission = Submission.find(submission_id)
    submission.update(status: Status.process, started_at: DateTime.now, execution_host: ENV["HOSTNAME"])

    initialize_workdir

    if compile == :failure
      cleanup(false)
      return
    end

    time = []
    memory = []

    tests = parse_tests_payload
    runs_count = tests ? tests.size : submission.number_of_runs
    test_results = []

    runs_count.times do |idx|
      if tests
        prepare_test_case(tests[idx])
      else
        reset_test_state
      end

      run
      verify_test_case(tests ? tests[idx] : nil)

      time << (submission.time || 0)
      memory << (submission.memory || 0)

      if tests
        test_results << {
          test_index: idx + 1,
          status: Status.find_by(id: submission.status_id).try(:name),
          status_id: submission.status_id,
          time: submission.time,
          memory: submission.memory,
          stdout: submission.stdout,
          stderr: submission.stderr
        }
      end

      break if submission.status_id != Status.ac.id
    end

    submission.time = time.empty? ? 0 : (time.inject(&:+).to_f / time.size).round(3)
    submission.memory = memory.empty? ? 0 : (memory.inject(&:+).to_f / memory.size).round
    if tests && test_results.any?
      submission.message = JSON.generate({
        "tests_total" => tests.size,
        "tests_run" => test_results.size,
        "all_passed" => (submission.status_id == Status.ac.id),
        "results" => test_results
      })
    end
    submission.save

  rescue Exception => e
    raise e.message unless submission
    submission.update(message: e.message, status: Status.boxerr, finished_at: DateTime.now)
  ensure
    cleanup(false)
    call_callback
    notify_completion
  end

  private

  # The number of programs this submission will run. The controller packs
  # per-test inputs into the stdin column as a single JSON document, so the
  # count is only knowable after decoding it.
  def test_count
    tests = parse_tests_payload
    tests ? tests.size : submission.number_of_runs.to_i
  end

  def initialize_workdir
    # ponytail: modulo the sandbox count, not 2^31-1. Upstream isolate honours
    # num_boxes (1000 in /usr/local/etc/isolate) and rejects any higher box id
    # with "Sandbox ID out of range", which every submission past id 999 hit.
    # Ceiling: two submissions exactly 1000 apart running at the same instant
    # would share a box. With a handful of concurrent workers that is not worth
    # a per-worker id partition; add one if this ever needs real throughput.
    @box_id = submission.id % 1000
    @cgroups = (!submission.enable_per_process_and_thread_time_limit || !submission.enable_per_process_and_thread_memory_limit) ? "--cg" : ""
    @workdir = SandboxCommand.capture(base_argv(["-b", box_id.to_s, "--init"])).chomp
    @boxdir = workdir + "/box"
    @tmpdir = workdir + "/tmp"
    @source_file = boxdir + "/" + submission.language.source_file.to_s

    # Ephemeral I/O directory in RAM-backed tmpfs (/dev/shm)
    @shm_dir = "/dev/shm/judge0/#{@box_id}"
    FileUtils.mkdir_p(@shm_dir)

    @stdin_file = File.join(@shm_dir, STDIN_FILE_NAME)
    @stdout_file = File.join(@shm_dir, STDOUT_FILE_NAME)
    @stderr_file = File.join(@shm_dir, STDERR_FILE_NAME)
    @metadata_file = File.join(@shm_dir, METADATA_FILE_NAME)
    @compile_output_file = File.join(@shm_dir, "compile_output.txt")
    @additional_files_archive_file = boxdir + "/" + ADDITIONAL_FILES_ARCHIVE_FILE_NAME

    [stdin_file, stdout_file, stderr_file, metadata_file, @compile_output_file].each do |f|
      File.write(f, "")
    end

    File.open(source_file, "wb") { |f| f.write(submission.source_code) } unless submission.is_project
    File.open(stdin_file, "wb") { |f| f.write(submission.stdin.to_s) }

    extract_archive
  end

  def initialize_file(file)
    File.write(file, "")
  end

  # The interpreter to launch when neither a project script nor a converted
  # argv is available: upstream's generated-script path. Only the basename is
  # used, because Isolate runs the command with the box directory as its
  # working directory.
  def script_plan(script_path)
    { argv: ["/bin/bash", File.basename(script_path)], env: {} }
  end

  def default_binary_name
    "a.out"
  end

  # `--cg-timing` is how per-process CPU time is measured. A request that asks
  # for per-process and thread limits can only be honoured without it, and when
  # there are no cgroups at all the flag is dropped.
  def timing_flag
    return "--cg-timing" unless submission.enable_per_process_and_thread_time_limit
    cgroups.present? ? "--no-cg-timing" : nil
  end

  # `-m N` bounds address space, `--cg-mem=N` bounds the cgroup; the request
  # picks one. Two argv tokens, because that is exactly what the shell used to
  # produce from "-m 512000" - passing it as one token leaks a leading space
  # into Isolate's own integer parsing.
  def memory_limit_args(per_process, limit)
    per_process ? ["-m", limit.to_s] : ["--cg-mem=#{limit}"]
  end

  # The program name inside the box, taken from the first argv token that
  # resolves to a file in the box ("./a.out", "./main"). Executing Isolate by
  # argv means read_cmd no longer has to be derived from a shell string.
  def run_binary_name(plan)
    token = plan[:argv].find { |a| a.start_with?("./") }
    token ? File.basename(token) : default_binary_name
  end

  def print_command(phase, command)
    puts "[#{DateTime.now}] #{phase} submission #{submission.token} (#{submission.id}):"
    puts command.to_s.gsub(/\s+/, " ")
    puts
  end

  # The argv prefix every Isolate call shares: the binary, the optional cgroup
  # mode, and whatever flags this particular invocation needs. Lifecycle calls
  # (--init, --cleanup) stop here; compile and run continue into sandbox_argv.
  def base_argv(flags)
    args = ["isolate"]
    args << cgroups if cgroups.present?
    args.concat(flags.compact)
    args
  end

  # Base argv shared by the compile and run invocations.
  def sandbox_argv(flags, plan, plan_env: {})
    args = base_argv(flags)

    # -E KEY (pass through from the worker env) versus -E KEY=value (set it)
    # versus -E VAR= (clear it) are three different things to Isolate, so an
    # assignment always carries its value explicitly.
    plan_env.each { |k, v| args.concat(["-E", "#{k}=#{v}"]) } if plan_env.present?
    args.concat(isolate_env_args)

    args.concat(["-d", "/etc:noexec", "-b", box_id.to_s])
    args.concat(["--run"])
    args << "--"
    args.concat(plan[:argv])
    args
  end

  # LANG and friends are passed through only when the worker has them set:
  def isolate_env_args
    args = ["-E", "HOME=/tmp",
            "-E", "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"]
    %w[LANG LANGUAGE LC_ALL JUDGE0_HOMEPAGE JUDGE0_SOURCE_CODE JUDGE0_MAINTAINER JUDGE0_VERSION].each do |name|
      args.concat(["-E", name])
    end
    args
  end

  def extract_archive
    return unless submission.additional_files?

    File.open(additional_files_archive_file, "wb") { |f| f.write(submission.additional_files) }

    # Same argv shape as compile and run, for the same reason: as a shell string
    # the per-process memory branch interpolated "-m " and the sandboxed unzip
    # received the empty variable name as its memory limit instead of the number.
    command = SandboxCommand.run(
      sandbox_argv(
        ["-s",
         "-b", box_id.to_s,
         "--stderr-to-stdout",
         "-t", "2",
         "-x", "1",
         "-w", "4",
         "-k", Config::MAX_STACK_LIMIT.to_s,
         "-p#{Config::MAX_MAX_PROCESSES_AND_OR_THREADS}",
         timing_flag,
         *memory_limit_args(submission.enable_per_process_and_thread_memory_limit, Config::MAX_MEMORY_LIMIT),
         "-f", Config::MAX_EXTRACT_SIZE.to_s].flatten,
        { argv: ["/usr/bin/unzip", "-n", "-qq", ADDITIONAL_FILES_ARCHIVE_FILE_NAME], env: {} }
      ),
      stdout_to: File::NULL
    )

    print_command("Extracting archive", command)
    command.wait

    File.delete(additional_files_archive_file)
  end

  def compile
    unless submission.is_project
      return :success unless submission.language.compile_cmd
    end

    compile_script = boxdir + "/" + "compile.sh"
    compile_plan = nil

    acceptable_project_compile_scripts = [compile_script, boxdir + "/" + "compile"]
    if submission.is_project
      compile_file_exists = false
      acceptable_project_compile_scripts.each do |f|
        if File.file?(f)
          compile_script = f
          compile_file_exists = true
          break
        end
      end

      unless compile_file_exists
        return :success # If compile script does not exist then this project does not need to be compiled.
      end
    else
      # Compiler options handling
      compiler_options = submission.compiler_options.to_s.strip.encode("UTF-8", invalid: :replace).gsub(/[$&;<>|`]/, "")
      if compiler_options.blank? && submission.language&.name =~ /C\+\+/i
        compiler_options = "-O0 -pipe"
      end

      # Determine expected binary name from run_cmd (e.g. ./a.out or ./main)
      binary_name = run_plan ? run_binary_name(run_plan) : default_binary_name

      # Check compilation cache
      cache_k = CompilationCache.cache_key(submission, compiler_options)
      if cache_k && (cached = CompilationCache.lookup(cache_k))
        # A recorded failure: the same source produced these diagnostics before,
        # so return them without spending a compile. Handled exactly like a
        # fresh compilation error so nothing downstream can tell the difference.
        if cached[:failed]
          puts "[#{DateTime.now}] Compilation cache HIT (error) for submission #{submission.token}"
          return compilation_error(cached[:compile_output])
        end

        target_path = File.join(boxdir, cached[:binary_name] || binary_name)
        FileUtils.cp(cached[:binary_path], target_path)
        File.chmod(0755, target_path)
        submission.compile_output = cached[:compile_output]
        puts "[#{DateTime.now}] Compilation cache HIT for submission #{submission.token}"
        return :success
      end

      # C++ compiles get the image's precompiled header directory on the include
      # path when it verified (see Pch), which is what stops every submission
      # from parsing <iostream> and the standard headers it pulls in again.
      # `Pch.include_args` is empty when the PCH is missing or fails its digest,
      # so a damaged PCH costs the old compile time and never a failed
      # submission. The flag is appended to the command string, not to a parsed
      # argv, so ExecPlan stays the one parser and its round-trip check still
      # applies to everything the sandbox will execute.
      compile_args = [submission.language.compile_cmd % compiler_options]
      compile_args.concat(Pch.include_args) if submission.language&.name =~ /C\+\+/i
      compile_cmd = compile_args.join(" ")

      compile_plan = ExecPlan.parse(compile_cmd)
      unless compile_plan
        File.open(compile_script, "w") { |f| f.write(compile_cmd) }
      end
    end

    compile_output_file = @compile_output_file
    File.write(compile_output_file, "")

    command = SandboxCommand.run(
      sandbox_argv(
      ["-s",
       "-M", metadata_file,
       "--stderr-to-stdout",
       "-i", "/dev/null",
       "-t", Config::MAX_CPU_TIME_LIMIT.to_s,
       "-x", "0",
       "-w", Config::MAX_WALL_TIME_LIMIT.to_s,
       "-k", Config::MAX_STACK_LIMIT.to_s,
       "-p#{Config::MAX_MAX_PROCESSES_AND_OR_THREADS}",
       timing_flag,
       *memory_limit_args(submission.enable_per_process_and_thread_memory_limit, Config::MAX_MEMORY_LIMIT),
       "-f", Config::MAX_MAX_FILE_SIZE.to_s].flatten,
      compile_plan || script_plan(compile_script),
        plan_env: compile_plan ? compile_plan[:env] : {}
      ),
      stdout_to: compile_output_file
    )

    print_command("Compiling", command)
    process_status = command.wait

    compile_output = File.read(compile_output_file)
    compile_output = nil if compile_output.empty?
    submission.compile_output = compile_output

    metadata = get_metadata

    reset_metadata_file

    files_to_remove = [compile_output_file]
    files_to_remove << compile_script unless submission.is_project
    files_to_remove.each do |f|
      File.unlink(f) rescue nil
    end

    if process_status.success?
      if cache_k && binary_name
        produced_binary = File.join(boxdir, binary_name)
        if File.exist?(produced_binary)
          CompilationCache.store(cache_k, produced_binary, submission.compile_output, binary_name)
          puts "[#{DateTime.now}] Stored binary in compilation cache for submission #{submission.token}"
        end
      end
      return :success
    end

    if metadata[:status] == "TO"
      submission.compile_output = "Compilation time limit exceeded."
    elsif cacheable_compile_failure?(metadata[:status])
      # The compiler ran to completion and exited nonzero on this exact source
      # and these exact flags. Retrying the same broken source is the single
      # most common student action, so record the diagnostics and skip the
      # compile next time.
      #
      # Only genuine compiler errors are cached. "XX" means the sandbox itself
      # failed and "TO" means the 20s compile allowance ran out; both are
      # properties of this attempt rather than of the source, and caching either
      # would make a transient fault permanent for that submission.
      CompilationCache.store_failure(cache_k, submission.compile_output) if cache_k
    end

    compilation_error(submission.compile_output)
  end

  def cacheable_compile_failure?(isolate_status)
    isolate_status == "RE" && submission.compile_output.present?
  end

  # The single definition of "this submission failed to compile", shared by the
  # real compiler path and the cache-hit path so a cached failure is
  # indistinguishable from a fresh one in the API response.
  def compilation_error(compile_output)
    submission.compile_output = compile_output
    submission.finished_at = DateTime.now
    submission.time = nil
    submission.wall_time = nil
    submission.memory = nil
    submission.stdout = nil
    submission.stderr = nil
    submission.exit_code = nil
    submission.exit_signal = nil
    submission.message = nil
    submission.status = Status.ce
    submission.save

    :failure
  end

  def run
    # A project ships its own run script, and command line arguments are
    # shell-like by contract, so both keep going through a generated script.
    # Everything else execs the language's run command directly.
    plan =
      if submission.is_project
        script_plan(project_run_script)
      elsif command_line_arguments.present?
        script_plan(build_run_script)
      else
        run_plan || script_plan(build_run_script)
      end

    command = SandboxCommand.run(
      sandbox_argv(
      ["-s",
       "-M", metadata_file,
       submission.redirect_stderr_to_stdout ? "--stderr-to-stdout" : nil,
       submission.enable_network ? "--share-net" : nil,
       "-t", submission.cpu_time_limit.to_s,
       "-x", submission.cpu_extra_time.to_s,
       "-w", submission.wall_time_limit.to_s,
       "-k", submission.stack_limit.to_s,
       "-p#{submission.max_processes_and_or_threads}",
       timing_flag,
       *memory_limit_args(submission.enable_per_process_and_thread_memory_limit, submission.memory_limit),
       "-f", submission.max_file_size.to_s].flatten,
      plan,
        plan_env: plan[:env]
      ),
      stdin_from: stdin_file,
      stdout_to: stdout_file,
      # Always the worker's own diagnostics file. `--stderr-to-stdout` above
      # already moves the *program's* stderr, and Isolate's messages must not
      # end up inside the submission's stdout.
      stderr_to: stderr_file
    )

    print_command("Running", command)
    command.wait

    # A generated script is per-submission scratch; a project's own script is
    # part of the box and is left where the project put it.
    FileUtils.rm_f(run_script_path) unless submission.is_project
  end

  def verify
    submission.finished_at = DateTime.now

    metadata = get_metadata

    program_stdout = File.read(stdout_file)
    program_stdout = nil if program_stdout.empty?

    program_stderr = File.read(stderr_file)
    program_stderr = nil if program_stderr.empty?

    submission.time = metadata[:time]
    submission.wall_time = metadata[:"time-wall"]
    submission.memory = (metadata[:"cg-mem"] || metadata[:"max-rss"]).try(:to_i)
    submission.stdout = program_stdout
    submission.stderr = program_stderr
    submission.exit_code = metadata[:exitcode].try(:to_i) || 0
    submission.exit_signal = metadata[:exitsig].try(:to_i)
    submission.message = metadata[:message]
    submission.status = determine_status(metadata[:status], submission.exit_signal)

    if submission.status == Status.boxerr &&
       (
         submission.message.to_s.match(/^execve\(.+\): Exec format error$/) ||
         submission.message.to_s.match(/^execve\(.+\): No such file or directory$/) ||
         submission.message.to_s.match(/^execve\(.+\): Permission denied$/)
       )
       submission.status = Status.exeerr
    end
  end

  def cleanup(raise_exception = true)
    FileUtils.rm_rf(@shm_dir) if @shm_dir && Dir.exist?(@shm_dir)
    SandboxCommand.run(
      base_argv(["-b", box_id.to_s, "--cleanup"]),
      stdout_to: File::NULL,
      stderr_to: File::NULL
    ).wait
    raise "Cleanup of sandbox #{box_id} failed." if raise_exception && Dir.exist?(workdir)
  end

  def reset_metadata_file
    File.write(metadata_file, "")
  end

  def call_callback
    return unless submission.callback_url.present?

    serialized_submission = ActiveModelSerializers::SerializableResource.new(
      submission,
      {
        serializer: SubmissionSerializer,
        base64_encoded: true,
        fields: SubmissionSerializer.default_fields
      }
    ).to_json

    Config::CALLBACKS_MAX_TRIES.times do
      begin
        response = HTTParty.put(
          submission.callback_url,
          body: serialized_submission,
          headers: {
            "Content-Type" => "application/json"
          },
          timeout: Config::CALLBACKS_TIMEOUT
        )
        break
      rescue Exception => e
      end
    end
  rescue Exception => e
  end

  def get_metadata
    metadata = File.read(metadata_file).split("\n").collect do |e|
      { e.split(":").first.to_sym => e.split(":")[1..-1].join(":") }
    end.reduce({}, :merge)
    return metadata
  end

  def determine_status(status, exit_signal)
    if status == "TO"
      return Status.tle
    elsif status == "SG"
      return Status.find_runtime_error_by_status_code(exit_signal)
    elsif status == "RE"
      return Status.nzec
    elsif status == "XX"
      return Status.boxerr
    elsif submission.expected_output.nil? || strip(submission.expected_output) == strip(submission.stdout)
      return Status.ac
    else
      return Status.wa
    end
  end

  def strip(text)
    return nil unless text
    text.split("\n").collect(&:rstrip).join("\n").rstrip
  rescue ArgumentError
    return text
  end

  def parse_tests_payload
    self.class.tests_payload(submission.stdin)
  end

  # Explicit command line arguments are shell-like by contract, so they are the
  # one thing that has to keep running through a script.
  def command_line_arguments
    @command_line_arguments ||=
      submission.command_line_arguments.to_s.strip.encode("UTF-8", invalid: :replace).gsub(/[$&;<>|`]/, "")
  end

  # Memoised because both compile and run need it and it does not change during
  # a job: the run command typically names the binary the compile command just
  # produced.
  def run_plan
    return @run_plan if defined?(@run_plan)
    @run_plan = ExecPlan.parse(submission.language.run_cmd) unless submission.is_project
  end

  # The generated script is what upstream wrote to run.sh. A project supplies
  # its own instead, preferring "run.sh" over a bare "run".
  def build_run_script
    FileUtils.rm_f(run_script_path)
    File.open(run_script_path, "w") do |f|
      f.write("#{submission.language.run_cmd} #{command_line_arguments}")
    end
    "run.sh"
  end

  def project_run_script
    return "run.sh" if File.file?(run_script_path)
    return "run" if File.file?(File.join(boxdir, "run"))
    # Default matches upstream: a project with no run script of its own gets
    # "run.sh", and the resulting "No such file or directory" is the verdict.
    "run.sh"
  end

  def run_script_path
    File.join(boxdir, "run.sh")
  end

  def prepare_test_case(test_case)
    test_stdin = test_case["stdin"].to_s
    File.write(stdin_file, test_stdin)
    reset_test_state
  end

  def reset_test_state
    File.write(stdout_file, "")
    File.write(stderr_file, "")
    File.write(metadata_file, "")
  end

  def verify_test_case(test_case = nil)
    verify
    if test_case && test_case.key?("expected_output")
      expected = test_case["expected_output"].to_s
      actual = submission.stdout.to_s
      if submission.status == Status.ac && strip(expected) != strip(actual)
        submission.status = Status.wa
      end
    end
  end

  def notify_completion
    Judge0Redis.notify_done(submission&.token)
  end
end
