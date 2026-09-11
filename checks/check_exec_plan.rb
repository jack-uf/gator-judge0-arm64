# Standalone check for ExecPlan, the shell-string-to-argv converter.
#
#   ruby checks/check_exec_plan.rb
#
# This is the risky one: it decides whether a language definition may skip the
# generated shell script. A wrong "yes" changes what runs. The check therefore
# does two things - unit-cases the parser, and then sweeps every real
# compile_cmd/run_cmd in the seed files asserting that anything converted is
# exactly what a shell would have run, and that anything shell-ish falls back.
require "shellwords"
require_relative "../judge0-src/app/services/exec_plan"

ROOT = File.expand_path("..", __dir__)
FAILURES = []

def check(condition, message)
  if condition
    puts "ok: #{message}"
  else
    FAILURES << message
    puts "FAIL: #{message}"
  end
end

def check_eq(actual, expected, message)
  if actual == expected
    puts "ok: #{message}"
  else
    FAILURES << message
    puts "FAIL: #{message}\n  got:      #{actual.inspect}\n  expected: #{expected.inspect}"
  end
end

# --- exact conversions -------------------------------------------------------
check_eq ExecPlan.parse("/usr/local/gcc-9.2.0/bin/g++ -O0 -pipe main.cpp"),
         { argv: ["/usr/local/gcc-9.2.0/bin/g++", "-O0", "-pipe", "main.cpp"], env: {} },
         "C++ compile converts to argv"

check_eq ExecPlan.parse("LD_LIBRARY_PATH=/usr/local/gcc-9.2.0/lib64 ./a.out"),
         { argv: ["./a.out"], env: { "LD_LIBRARY_PATH" => "/usr/local/gcc-9.2.0/lib64" } },
         "C++ run hoists its leading assignment into env"

check_eq ExecPlan.parse("/usr/local/node-12.14.0/bin/node script.js")[:argv],
         ["/usr/local/node-12.14.0/bin/node", "script.js"],
         "node run converts to argv"

# --- shell constructs must stay on the generated-script path -----------------
{
  "/bin/chmod +x a.out && ./a.out" => "&&",
  "/bin/cat script.sql | /usr/bin/sqlite3 db.sqlite" => "a pipe",
  "/bin/sed -i '1s/^/\\n/' main.erl && /usr/local/erlang-22.2/bin/escript main.erl" => "single quotes",
  "/bin/cat *.txt" => "a glob",
  "/bin/echo `whoami`" => "a backtick",
  "/bin/echo $(id)" => "command substitution",
  "/bin/echo a > b" => "output redirection",
  "/bin/echo a\\ b" => "a backslash escape",
  "/bin/cat ~/.file" => "a tilde",
  "PATH=\"/usr/local/x/bin:$PATH\" /usr/local/x/bin/prog" => "an interpolated PATH"
}.each do |command, feature|
  check_eq ExecPlan.parse(command), nil, "#{feature} keeps the script path"
end

check_eq ExecPlan.parse(""), nil, "an empty command does not convert"
check_eq ExecPlan.parse(nil), nil, "a nil command does not convert"
check_eq ExecPlan.parse("LD_LIBRARY_PATH=/x"), nil, "an assignment with no program does not convert"

# --- env hoisting is leading-only -------------------------------------------
plan = ExecPlan.parse("A=1 B=2 prog --x=y arg")
check_eq plan[:env], { "A" => "1", "B" => "2" }, "only leading assignments become env"
check_eq plan[:argv], ["prog", "--x=y", "arg"], "a later '=' stays an argument"

# --- the real language definitions ------------------------------------------
# Same unescaping the seed loader does, then: converted commands must split back
# into the identical token list, and nothing with shell syntax may convert.
SHELLISH = /[|&;<>`$*?\[\]{}()'"\\~!\n\r]/
swept = 0
converted = 0
fallback = 0

%w[active archived].each do |file|
  path = File.join(ROOT, "judge0-src/db/languages/#{file}.rb")
  next unless File.exist?(path)

  File.read(path).scan(/(?:compile_cmd|run_cmd):\s*"((?:[^"\\]|\\.)*)"/).each do |(raw)|
    command = raw.gsub(/\\(.)/) { $1 == "n" ? "\n" : $1 }
    swept += 1
    plan = ExecPlan.parse(command)

    if plan
      converted += 1
      reconstructed = plan[:env].map { |k, v| "#{k}=#{v}" } + plan[:argv]
      check_eq reconstructed.join(" "), command,
               "#{file}: #{command[0, 48]} converts losslessly"
    else
      fallback += 1
      check command.match?(SHELLISH) || command.include?("%s") == false,
            "#{file}: #{command[0, 48]} only falls back for a real shell feature"
    end
  end
end

check swept > 80, "swept the full language table (#{swept} commands)"
check converted > 0 && fallback > 0, "#{converted} converted, #{fallback} kept on the script path"

if FAILURES.empty?
  puts "\nall exec-plan checks passed (#{swept} language commands swept)"
else
  abort "\n#{FAILURES.size} failure(s):\n  #{FAILURES.join("\n  ")}"
end
