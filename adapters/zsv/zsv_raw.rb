# frozen_string_literal: true

require_relative "../base"

module Adapters
  module ZSV
    # ZSV raw parsing — returns Array<Array<String>>, header row included as row 0.
    # Exempt from equivalence tests (output_type: :raw).
    #
    # NOTE: zsv-ruby 1.3.1 has a GC marking bug on Ruby 3.4.x that causes crashes
    # on large files. GC is disabled during ZSV calls. This gives ZSV a slight
    # speed advantage (no GC pauses during its run) — noted in benchmark output.
    class ZsvRaw < Base
      def name        = "ZSV.read (raw arrays)"
      def label       = "ZSV.read"
      def output_type = :raw

      def available?
        require "zsv"
        true
      rescue LoadError
        false
      end

      def accepts?(**opts)
        opts.fetch(:col_sep, ",").length == 1  # ZSV supports single-char delimiters only
      end

      def call(filepath, col_sep: ",", quote_char: '"', liberal_parsing: false, **_)
        GC.disable
        result = ::ZSV.read(filepath, col_sep: col_sep, quote_char: quote_char, liberal_parsing: liberal_parsing)
        GC.enable
        result
      end
    end
  end
end
