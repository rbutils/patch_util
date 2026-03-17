# frozen_string_literal: true

require 'time'

module PatchUtil
  module Split
    class Planner
      def initialize(verifier: Verifier.new)
        @verifier = verifier
      end

      def build(source:, diff:, chunk_requests:)
        chunks = @verifier.build_chunks(diff: diff, chunk_requests: chunk_requests)
        PlanEntry.new(
          source_kind: source.kind,
          source_label: source.label,
          source_fingerprint: source.fingerprint,
          chunks: chunks,
          created_at: Time.now.utc.iso8601
        )
      end
    end
  end
end
