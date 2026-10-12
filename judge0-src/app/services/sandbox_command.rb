require "shellwords"

# Runs one Isolate invocation without going through a shell.
#
# Upstream builds every isolate call as a string and hands it to a shell, which
# means each submission pays for an extra `/bin/sh`, plus interpolation of the
# stdin/stdout paths and the language's run command into that string. Passing
# argv directly removes the extra process and the last place where submission
# text is interpreted by a shell.
#
# Redirections are set up with IO.popen options rather than by asking a shell to
# open the files, so a path can never be parsed as syntax.
class SandboxCommand
  attr_reader :argv, :pid

  def self.run(argv, stdin_from: nil, stdout_to: nil, stderr_to: nil)
    new(argv, stdin_from: stdin_from, stdout_to: stdout_to, stderr_to: stderr_to).tap(&:spawn)
  end

  # Runs Isolate and returns its stdout, for the invocations whose output is a
  # value rather than a log (`isolate --init` prints the box's working
  # directory). An argv array is passed to IO.popen, which therefore never
  # consults a shell.
  def self.capture(argv)
    io = IO.popen(argv, "r")
    output = io.read
    io.close
    @last_status = $?
    output
  end

  def self.last_status
    @last_status
  end

  def initialize(argv, stdin_from:, stdout_to:, stderr_to:)
    @argv = argv
    @stdin_from = stdin_from
    @stdout_to = stdout_to
    @stderr_to = stderr_to
    @status = nil
  end

  def spawn
    @pid = Process.spawn(*argv, redirections)
    self
  end

  # @return [Process::Status]
  def wait
    Process.wait(pid)
    @status = $?
    @status
  end

  def status
    @status
  end

  def to_s
    Shellwords.join(argv)
  end

  private

  def redirections
    redirections = {}
    redirections[:in] = [@stdin_from, File::RDONLY] if @stdin_from
    redirections[:out] = [@stdout_to, File::WRONLY | File::CREAT | File::TRUNC] if @stdout_to
    redirections[:err] = [@stderr_to, File::WRONLY | File::CREAT | File::TRUNC] if @stderr_to
    redirections
  end
end
