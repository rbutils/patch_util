# frozen_string_literal: true

module PatchUtil
  module Split
    class Verifier
      def initialize(selector_parser: PatchUtil::Selection::Parser.new)
        @selector_parser = selector_parser
      end

      def build_chunks(diff:, chunk_requests:)
        chunks = []
        assigned_row_ids = {}
        leftovers_request = nil

        chunk_requests.each do |request|
          if request.leftovers?
            raise ValidationError, 'leftovers chunk can only be declared once' if leftovers_request

            leftovers_request = request
            next
          end

          selectors = @selector_parser.parse(request.selector_text)
          row_ids, change_labels = resolve_selectors(diff, selectors)

          row_ids.each do |row_id|
            existing = assigned_row_ids[row_id]
            next unless existing

            label = diff.row_by_id(row_id)&.change_label || row_id
            raise ValidationError, "#{label} is assigned to both #{existing} and #{request.name}"
          end

          row_ids.each { |row_id| assigned_row_ids[row_id] = request.name }

          chunks << Chunk.new(
            name: request.name,
            selector_text: request.selector_text,
            row_ids: row_ids,
            change_labels: change_labels,
            leftovers: false
          )
        end

        leftovers = []
        diff.change_rows.each do |row|
          leftovers << row unless assigned_row_ids.key?(row.id)
        end

        if leftovers.any?
          unless leftovers_request
            raise ValidationError,
                  "#{leftovers.length} lines will be removed; re-plan with a leftovers commit if you do not intend removal"
          end

          row_ids = leftovers.map(&:id)
          change_labels = leftovers.map(&:change_label)
          chunks << Chunk.new(
            name: leftovers_request.name,
            selector_text: nil,
            row_ids: row_ids,
            change_labels: change_labels,
            leftovers: true
          )
        elsif leftovers_request
          chunks << Chunk.new(
            name: leftovers_request.name,
            selector_text: nil,
            row_ids: [],
            change_labels: [],
            leftovers: true
          )
        end

        chunks
      end

      private

      def resolve_selectors(diff, selectors)
        whole_hunks = {}
        partial_hunks = {}

        selectors.each do |selector|
          if selector.whole_hunk?
            whole_hunks[selector.hunk_label] = true
          else
            partial_hunks[selector.hunk_label] = true
          end
        end

        whole_hunks.each_key do |hunk_label|
          next unless partial_hunks[hunk_label]

          raise ValidationError, "cannot select both whole hunk #{hunk_label} and partial changed lines from it"
        end

        selected_row_ids = []
        selected_change_labels = []
        seen_row_ids = {}

        selectors.each do |selector|
          rows = rows_for_selector(diff, selector)
          rows.each do |row|
            raise ValidationError, "#{row.change_label} is selected more than once" if seen_row_ids[row.id]

            seen_row_ids[row.id] = true
            selected_row_ids << row.id
            selected_change_labels << row.change_label
          end
        end

        [selected_row_ids, selected_change_labels]
      end

      def rows_for_selector(diff, selector)
        hunk = diff.hunk_by_label(selector.hunk_label)
        raise ValidationError, "unknown hunk label: #{selector.hunk_label}" unless hunk

        return hunk.change_rows if selector.whole_hunk?

        rows = []
        selector.ordinals.each do |ordinal|
          row = hunk.change_rows.find { |candidate| candidate.change_ordinal == ordinal }
          raise ValidationError, "unknown changed line #{selector.hunk_label}#{ordinal}" unless row

          rows << row
        end
        rows
      end
    end
  end
end
