# frozen_string_literal: true

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

desc "Run equivalence specs then all benchmarks (specs must pass first)"
task bench: :spec do
  ruby "benchmarks/run_all.rb"
end

desc "Run cross-parser fair-comparison (specs must pass first)"
task compare: :spec do
  ruby "benchmarks/compare_parsers.rb"
end

desc "Run multi-version SmarterCSV comparison (specs must pass first)"
task versions: :spec do
  ruby "benchmarks/smarter_csv_versions.rb"
end

desc "Profile a single CSV file: rake profile[csv_files/actual/uscities.csv]"
task :profile, [:file] do |_t, args|
  abort "Usage: rake profile[path/to/file.csv]" unless args[:file]
  sh "ruby tools/csv_profile.rb #{args[:file]}"
end

ZIP_FILE = "csv_files.zip"

desc "Install: unzip CSV benchmark files (alias for unzip_csv)"
task install: :unzip_csv

desc "Zip all csv_files/ into #{ZIP_FILE} with clean permissions (no macOS extended attributes)"
task :zip_csv do
  sh "zip -rX #{ZIP_FILE} csv_files/"
  # Strip macOS extended attributes from the zip itself (removes the '@' flag in ls -l)
  system("xattr -cr #{ZIP_FILE} 2>/dev/null")
  sh "chmod 644 #{ZIP_FILE}"
  puts "Created #{ZIP_FILE}"
end

desc "Unzip #{ZIP_FILE} and restore csv_files/ with clean permissions"
task :unzip_csv do
  sh "unzip -o #{ZIP_FILE}"
  # Strip macOS extended attributes from extracted files
  system("find csv_files -type f -exec xattr -cr {} \\; 2>/dev/null")
  sh "find csv_files -type f -exec chmod 644 {} \\;"
  puts "Extracted #{ZIP_FILE}"
end

task default: :spec
