# frozen_string_literal: true

module PatchUtil
  module Split
    class Inspector
      COLUMN_WIDTH = 28

      def render(diff:, plan_entry: nil, compact: false, expand_hunks: [])
        assignments = assignment_map(plan_entry)
        return render_compact(diff, assignments, expand_hunks) if compact

        render_full(diff, assignments)
      end

      private

      def render_full(diff, assignments)
        lines = []

        diff.file_diffs.each do |file_diff|
          lines << "--- #{file_diff.old_path}"
          lines << "+++ #{file_diff.new_path}"

          file_diff.hunks.each do |hunk|
            lines << "@@ -#{hunk.old_start},#{hunk.old_count} +#{hunk.new_start},#{hunk.new_count} @@"
            hunk.rows.each do |row|
              if row.change?
                label = row.change_label
                chunk_name = assignments[row.id]
                marker = chunk_name ? "#{label} [#{chunk_name}]" : label
                lines << format("%-#{COLUMN_WIDTH}s %s%s", marker, row.display_prefix, row.text)
              else
                lines << format("%-#{COLUMN_WIDTH}s %s%s", '', row.display_prefix, row.text)
              end
            end
          end
        end

        lines.join("\n") + "\n"
      end

      def render_compact(diff, assignments, expand_hunks)
        lines = []
        expanded_labels = expand_hunks.to_set

        lines << '== Compact Inspect =='
        lines << 'legend: text=unified hunk, operation=rename/copy/mode metadata, binary=git binary payload'
        lines << 'label spans show selectable changed-line ranges with optional [chunk name] overlay'
        lines << "expanded hunks: #{expanded_labels.to_a.join(', ')}" unless expanded_labels.empty?
        lines << ''
        lines << '== File Index =='

        diff.file_diffs.each do |file_diff|
          lines << compact_file_index_line(file_diff, assignments)
        end

        lines << ''
        lines << '== Details =='

        diff.file_diffs.each do |file_diff|
          lines << "--- #{file_diff.old_path}"
          lines << "+++ #{file_diff.new_path}"

          file_diff.hunks.each do |hunk|
            if expanded_labels.include?(hunk.label)
              lines.concat(full_hunk_lines(hunk, assignments))
            else
              lines << compact_hunk_line(hunk, assignments)
            end
          end
        end

        lines.join("\n") + "\n"
      end

      def compact_file_index_line(file_diff, assignments)
        path = compact_file_path(file_diff)
        hunks = compact_index_hunks(file_diff).map { |hunk| compact_file_index_hunk(hunk, assignments) }
        change_count = 0
        file_diff.hunks.each do |hunk|
          change_count += hunk.change_rows.length
        end

        "#{path} (#{count_label(file_diff.hunks.length,
                                'hunk')}, #{count_label(change_count, 'change')}): #{hunks.join('; ')}"
      end

      def compact_file_path(file_diff)
        return file_diff.new_path if file_diff.addition?
        return file_diff.old_path if file_diff.deletion?

        file_diff.new_path
      end

      def compact_index_hunks(file_diff)
        indexed = []
        file_diff.hunks.each_with_index do |hunk, index|
          indexed << [hunk, index]
        end

        indexed.sort_by { |hunk, index| [-hunk.change_rows.length, index] }.map(&:first)
      end

      def compact_file_index_hunk(hunk, assignments)
        summary = compact_change_segments(hunk.change_rows, assignments)
        "#{hunk.label}(#{compact_kind(hunk)}, #{count_label(hunk.change_rows.length, 'change')}: #{summary})"
      end

      def compact_hunk_line(hunk, assignments)
        if hunk.text?
          "#{hunk.label} text @@ -#{hunk.old_start},#{hunk.old_count} +#{hunk.new_start},#{hunk.new_count} @@: " \
            "#{compact_change_segments(hunk.change_rows, assignments)}"
        else
          row = hunk.change_rows.first
          "#{hunk.label} #{compact_kind(hunk)}: #{compact_change_segments([row],
                                                                          assignments)} #{row.display_prefix}#{row.text}"
        end
      end

      def full_hunk_lines(hunk, assignments)
        lines = []
        lines << "#{compact_hunk_line(hunk, assignments)} [expanded]"

        lines << "@@ -#{hunk.old_start},#{hunk.old_count} +#{hunk.new_start},#{hunk.new_count} @@" if hunk.text?

        hunk.rows.each do |row|
          if row.change?
            label = row.change_label
            chunk_name = assignments[row.id]
            marker = chunk_name ? "#{label} [#{chunk_name}]" : label
            lines << format("%-#{COLUMN_WIDTH}s %s%s", marker, row.display_prefix, row.text)
          else
            lines << format("%-#{COLUMN_WIDTH}s %s%s", '', row.display_prefix, row.text)
          end
        end

        lines
      end

      def compact_change_segments(rows, assignments)
        segments = []
        range_start = nil
        range_end = nil
        current_chunk_name = nil

        rows.each do |row|
          chunk_name = assignments[row.id]

          if range_start && contiguous_segment?(range_end, row) && current_chunk_name == chunk_name
            range_end = row
            next
          end

          segments << compact_segment_label(range_start, range_end, current_chunk_name) if range_start
          range_start = row
          range_end = row
          current_chunk_name = chunk_name
        end

        segments << compact_segment_label(range_start, range_end, current_chunk_name) if range_start
        segments.join(', ')
      end

      def compact_segment_label(range_start, range_end, chunk_name)
        marker = if range_start.change_label == range_end.change_label
                   range_start.change_label
                 else
                   "#{range_start.change_label}-#{range_end.change_label}"
                 end
        chunk_name ? "#{marker} [#{chunk_name}]" : marker
      end

      def contiguous_segment?(left, right)
        left.change_ordinal + 1 == right.change_ordinal
      end

      def compact_kind(hunk)
        return 'text' if hunk.text?
        return 'operation' if hunk.operation?
        return 'binary' if hunk.binary?

        raise PatchUtil::UnsupportedFeatureError, "unknown hunk kind: #{hunk.kind.inspect}"
      end

      def count_label(count, singular)
        noun = count == 1 ? singular : "#{singular}s"
        "#{count} #{noun}"
      end

      def assignment_map(plan_entry)
        return {} unless plan_entry

        map = {}
        plan_entry.chunks.each do |chunk|
          chunk.row_ids.each do |row_id|
            map[row_id] = chunk.name
          end
        end
        map
      end
    end
  end
end
