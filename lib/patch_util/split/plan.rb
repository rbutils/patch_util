# frozen_string_literal: true

module PatchUtil
  module Split
    ChunkRequest = Data.define(:name, :selector_text, :leftovers) do
      def leftovers?
        leftovers
      end
    end

    Chunk = Data.define(:name, :selector_text, :row_ids, :change_labels, :leftovers) do
      def leftovers?
        leftovers
      end
    end

    PlanEntry = Data.define(:source_kind, :source_label, :source_fingerprint, :chunks, :created_at) do
      def matches_source?(source)
        source_kind == source.kind && source_fingerprint == source.fingerprint
      end

      def chunk_for_row_id(row_id)
        chunks.find { |chunk| chunk.row_ids.include?(row_id) }
      end
    end

    PlanSet = Data.define(:version, :entries) do
      def find_entry(source)
        entries.find { |entry| entry.matches_source?(source) }
      end
    end
  end
end
