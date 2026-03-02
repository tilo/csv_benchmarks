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
      def output_type = :raw

      def available?
        require "zsv"
        true
      rescue LoadError
        false
      end

      def call(filepath)
        GC.disable
        result = ::ZSV.read(filepath)
        GC.enable
        result
      end
    end
  end
end
