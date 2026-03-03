# frozen_string_literal: true

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

desc "Run all benchmarks (saves JSON to results/)"
task :bench do
  ruby "benchmarks/run_all.rb"
end

desc "Format benchmark results as Markdown: rake report[path/to/results.json]"
task :report, [:file] do |_t, args|
  file_arg = args[:file] ? " #{args[:file]}" : ""
  ruby "benchmarks/format_results.rb#{file_arg}"
end
task :results, [:file] => [] do |_t, args|
  Rake::Task[:report].invoke(args[:file])
end

desc "Run cross-parser fair-comparison"
task :compare do
  ruby "benchmarks/compare_parsers.rb"
end

desc "Run multi-version SmarterCSV comparison"
task :versions do
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
  sh "chmod 644 #{ZIP_FILE}"
  puts "Created #{ZIP_FILE}"
end

desc "Unzip #{ZIP_FILE} and restore csv_files/ with clean permissions"
task :unzip_csv do
  sh "unzip -o #{ZIP_FILE}"
  sh "find csv_files -type f -exec chmod 644 {} \\;"
  puts "Extracted #{ZIP_FILE}"
end

task default: :spec
