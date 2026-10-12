# Shellwords provides the argv join for sandbox_command and the split used to
# decide whether a language definition can run as a plain argv at all.
require "shellwords"

# Turns a language definition's compile/run command into an argv array so the
# sandbox can exec the target directly instead of re-parsing a generated shell
# script. That removes two process creations per test (the wrapper bash and the
# script bash) from every submission, which is where the fixed cost of a tiny
# program mostly goes.
#
# The transform is deliberately conservative. A language definition is a shell
# string and several of them legitimately rely on shell features (`&&`, `|`,
# quoting, pathname expansion). Those keep the old script path; only commands
# that are unambiguous as a plain argv are converted, and the fallback is always
# available. This is a translation of upstream's shell semantics, not a
# replacement for them, so anything the parser cannot prove safe stays on the
# original code path.
module ExecPlan
  # Tokens that mean the string is doing shell work rather than naming a
  # program. Checked after splitting, because "a && b" splits into tokens
  # including "&&" and would otherwise round-trip cleanly.
  SHELL_OPERATOR_TOKENS = %w[&& || | ; > >> < << &].freeze

  # Characters a caller may not smuggle into a converted command. These are the
  # ones that expand or re-parse under a shell: command substitution, globbing,
  # quoting, redirection, history, tilde, and the comment marker (`#` starts a
  # comment mid-line in a script but is just an argument in an argv).
  FORBIDDEN_CHARS = /[`$'"*?\[\]{}()<>\\!~#\n\r]/

  # Leading VAR=value assignments are the one env-var form upstream uses inside
  # run_cmd (for example LD_LIBRARY_PATH for the GCC toolchains). Isolate takes
  # them as -E KEY=value arguments instead.
  ENV_ASSIGNMENT = /\A[A-Za-z_][A-Za-z0-9_]*=[^\s]*\z/

  # @return [Hash, nil] { argv: [...], env: { "K" => "V" } } or nil when the
  #   command must stay on the generated-script path.
  def self.parse(command)
    command = command.to_s.strip
    return nil if command.empty?
    return nil if command.match?(FORBIDDEN_CHARS)

    tokens = Shellwords.split(command)
    return nil if tokens.empty?

    # Reject anything that did not survive splitting byte for byte. If the
    # splitter had to interpret escaping, the string was relying on shell
    # parsing and is not a plain argv.
    return nil unless tokens.join(" ") == command
    return nil if tokens.any? { |t| SHELL_OPERATOR_TOKENS.include?(t) }

    env = {}
    tokens = tokens.drop_while do |token|
      next false unless token.match?(ENV_ASSIGNMENT)
      key, value = token.split("=", 2)
      env[key] = value
      true
    end

    return nil if tokens.empty?
    return nil if tokens.first.include?("=")

    { argv: tokens, env: env }
  end
end
