# frozen_string_literal: true
#
# benchmarks/progress.rb — shared per-file progress display.
#
# Used by both the in-process adapter loop in benchmarks/run_all.rb and the
# per-version SmarterCSV subprocess heredoc inside the same file. The
# subprocess loads this file by absolute path, so they share one
# implementation.
#
# Output format:
#   [<label> ]<i>/<N> <filename> (<rows> rows)... <current>/<total>
# When total_iterations is 0, "done" becomes "cached" — there was no work to
# do because timings came from a prior subprocess run.

class BenchmarkProgress
  def initialize(file_index:, total_files:, filename:, rows:, total_iterations:, label: nil)
    @prefix  = build_prefix(label, file_index, total_files, filename, rows)
    @total   = total_iterations
    @current = 0
  end

  def start
    write_status
  end

  def tick
    return if cached?
    @current += 1
    write_status
  end

  def done
    msg = cached? ? "cached" : "done"
    $stderr.puts "\r#{@prefix}#{msg}#{' ' * 30}"
  end

  private

  def cached?
    @total.zero?
  end

  def build_prefix(label, idx, total_files, filename, rows)
    head = label ? "#{label} " : ""
    "#{head}[#{idx}/#{total_files}] #{filename} (#{rows} rows)... "
  end

  def write_status
    return if cached?
    $stderr.print "\r#{@prefix}#{@current}/#{@total}   "
    $stderr.flush
  end
end
