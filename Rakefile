# frozen_string_literal: true

require "rspec/core/rake_task"
require "shellwords"

RSpec::Core::RakeTask.new(:spec)

desc "Run all benchmarks (saves JSON to results/)"
task :bench do
  ruby "benchmarks/run_all.rb"
end

desc "Format benchmark results as Markdown: rake report [path/to/results.json] [version1 version2 ...] (NO_MD=1 to skip writing .md)"
task :report do
  args = ARGV.drop(1)
  args.each { |a| task(a.to_sym) {} }   # define no-op tasks so rake doesn't try to build them
  ruby "benchmarks/format_results.rb #{args.map(&:shellescape).join(' ')}"
end
task :results => [] do
  Rake::Task[:report].invoke
end

desc "Run cross-parser fair-comparison"
task :compare do
  ruby "benchmarks/compare_parsers.rb"
end

desc "Run multi-version SmarterCSV comparison"
task :versions do
  ruby "benchmarks/smarter_csv_versions.rb"
end

desc "Generate SVG version-speedup chart: rake chart_versions [path/to/results.json]"
task :chart_versions do
  file = ARGV.find { |a| a.end_with?(".json") }
  ARGV.clear
  file_arg = file ? " #{file}" : ""
  ruby "benchmarks/chart_versions.rb versions#{file_arg}"
end

desc "Generate SVG adapter-comparison chart: rake chart_adapters [path/to/results.json]"
task :chart_adapters do
  file = ARGV.find { |a| a.end_with?(".json") }
  ARGV.clear
  file_arg = file ? " #{file}" : ""
  ruby "benchmarks/chart_versions.rb adapters#{file_arg}"
end

desc "Generate SVG speedup bar chart (SmarterCSV C vs CSV.read): rake chart_speedup [path/to/results.json]"
task :chart_speedup do
  file = ARGV.find { |a| a.end_with?(".json") }
  ARGV.clear
  file_arg = file ? " #{file.shellescape}" : ""
  ruby "benchmarks/chart_speedup.rb#{file_arg}"
end

desc "Refresh canonical SmarterCSV cache files: rake merge_results 1.15.2 1.16.4"
task :merge_results do
  args = ARGV.drop(1)
  abort "Usage: rake merge_results <version> [<version>...]\nExample: rake merge_results 1.15.2 1.16.4" if args.empty?
  # Define no-op tasks for each version arg so rake doesn't try to build them.
  args.each { |a| task(a.to_sym) {} }
  ruby "tools/merge_results.rb #{args.map { |a| a.shellescape }.join(' ')}"
end

desc "Apples-to-apples cross-version comparison JSON: rake compare_versions p10 1.14.4 1.15.2 1.16.0 1.16.4 1.17.0.pre8"
task :compare_versions do
  args = ARGV.drop(1)
  abort "Usage: rake compare_versions <stats_method> <version1> [<version2>...]\nExample: rake compare_versions p10 1.14.4 1.16.4 1.17.0.pre8" if args.size < 2
  args.each { |a| task(a.to_sym) {} }
  ruby "tools/compare_versions.rb #{args.map { |a| a.shellescape }.join(' ')}"
end

desc "Retroactively add cached_versions marker to legacy results/202*.json files (DRY=1 to preview)"
task :backfill_cached_versions do
  dry = ENV["DRY"] ? " --dry-run" : ""
  ruby "tools/backfill_cached_versions.rb#{dry}"
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
