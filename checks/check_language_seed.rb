# Standalone check for the seeded language set.
#
#   ruby checks/check_language_seed.rb
#
# `db/seeds.rb` filters Judge0's upstream language list down to the languages
# this image can actually run. Two things can go wrong there, and both are
# silent in production: an id that no longer exists upstream (the row is simply
# never seeded, and the language disappears from the API with no error), and a
# dropped id that a client depends on. This check loads the real seed file with
# a stub `Language` and inspects what it would create.
#
# What this cannot check is whether the interpreter binaries are present -- that
# is a property of the built image, not of the source. It was measured once, in
# a container; run the submission checks after changing the Dockerfile's packages.
ROOT = File.expand_path("..", __dir__)
SEEDS = File.join(ROOT, "judge0-src/db/seeds.rb")

def check(condition, message)
  abort("FAIL: #{message}") unless condition
  puts "ok: #{message}"
end

# --- load the shipped seed file against a stub Language ----------------------
CREATED = []

module ActiveRecord
  class Base
    def self.transaction
      yield
    end
  end
end

class Language
  def self.unscoped
    self
  end

  def self.delete_all
    @deleted = true
  end

  def self.create(**attributes)
    CREATED << attributes
  end
end

load SEEDS

# `seeds.rb` loads both language files into the top-level `@languages`, so the
# check can ask the same data the seed did rather than re-parsing the files.
LANGUAGES_BY_ID = @languages.each_with_object({}) { |language, map| map[language[:id]] = language }

# --- the filter is applied, and it keeps the Gator++ set ---------------------
supported = Object.const_get(:SUPPORTED_LANGUAGE_IDS)
seeded = CREATED.map { |row| row[:id] }

check seeded == supported,
      "the seed creates exactly the supported ids (#{seeded.size} of them)"
check supported.uniq.size == supported.size,
      "the supported id list has no duplicates"
check supported == supported.sort,
      "the supported id list is sorted, so the diff stays readable"

# The C/C++ entries are the ones Gator++ submits against. If an upstream id is
# ever renumbered, this is the assertion that says so.
cpp_ids = LANGUAGES_BY_ID.select { |_, l| l[:name].match?(/\AC\+\+ \(GCC/) }.keys
check (cpp_ids & supported) == [54],
      "Gator++ uses one C++ compiler definition, id 54"
check CREATED.find { |row| row[:id] == 54 }[:compile_cmd] == "/usr/bin/g++ %s main.cpp",
      "the C++ definition invokes the installed native compiler"

# --- every supported id is real, and usable ---------------------------------
missing = supported - LANGUAGES_BY_ID.keys
check missing.empty?, "every supported id exists in the language files (#{missing.inspect})"

archived = supported.select { |id| LANGUAGES_BY_ID[id][:is_archived] }
check archived.empty?,
      "no supported id is archived, which submission validation would reject (#{archived.inspect})"

# --- the seeded rows carry what the API needs to describe a submission ------
# Same rule as `Language`: a project language is identified by its name and is
# the one kind of row allowed to have no `source_file`.
incomplete = CREATED.reject do |row|
  row[:name] && row[:is_archived] == false &&
    (row[:name] == "Multi-file program" || row[:source_file])
end
check incomplete.empty?,
      "every seeded row carries a name, a live flag and a source file " \
      "(except the project language)"

puts "\nall language-seed checks passed (#{seeded.size} languages seeded)"
