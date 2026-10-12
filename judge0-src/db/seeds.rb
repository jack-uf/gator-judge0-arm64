require_relative 'languages/archived'
require_relative 'languages/active'

# Only the languages this image can actually run are seeded.
#
# The upstream language list is much larger than the ARM64 worker image:
# `Dockerfile.arm64` ships the C/C++ toolchain plus the interpreters and shell
# utilities that Ubuntu's base layer already provides, and nothing else. Seeding
# a language whose interpreter is absent would still advertise it on
# `GET /languages`, and then hand the submission back a shell "not found" as its
# compile output -- a message that reads like a broken judge rather than a
# refusal. Filtering here turns it into a validation error that names the
# language, before a worker is ever involved.
#
# The list holds ids rather than names because `Language` is seeded by id and
# submission rows refer to it by id.
#
# Recovery: restore the interpreter's package to `Dockerfile.arm64`, rebuild,
# confirm that *every* path the language's `compile_cmd` and `run_cmd` reference
# resolves inside the container -- some entries need more than one binary, SQL
# needs both `sqlite3` and `cat` -- then add the id back here.
#
# Source of the list, and the probe that produced it:
# OPTIMIZATION_REPORT.md, "C++-only ARM64 worker image".
SUPPORTED_LANGUAGE_IDS = [43, 44, 46, 48, 49, 50, 52, 53, 54, 85, 89].freeze

ActiveRecord::Base.transaction do
  Language.unscoped.delete_all
  @languages.each do |language|
    next unless SUPPORTED_LANGUAGE_IDS.include?(language[:id])

    Language.create(
      id: language[:id],
      name: language[:name],
      is_archived: language[:is_archived],
      source_file: language[:source_file],
      compile_cmd: language[:compile_cmd],
      run_cmd: language[:run_cmd],
    )
  end
end
