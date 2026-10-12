require_relative 'languages/archived'
require_relative 'languages/active'

# Modified for Gator++ on 2026-10-12: use only the native runtime definitions.
# Keep this list aligned with the installed toolchains in Dockerfile.arm64.
SUPPORTED_LANGUAGE_IDS = [46, 50, 54, 85, 89].freeze

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
