# frozen_string_literal: true

module PatchUtil
  module Split
    ProjectedFile = Data.define(:old_path, :new_path, :diff_git_line, :metadata_lines, :hunks, :emit_text_headers)
    ProjectedHunk = Data.define(:old_start, :old_count, :new_start, :new_count, :lines, :kind, :patch_lines)

    class Projector
      def initialize(diff:, plan_entry:)
        @diff = diff
        @plan_entry = plan_entry
        @chunk_index_by_row_id = {}

        @plan_entry.chunks.each_with_index do |chunk, chunk_index|
          chunk.row_ids.each do |row_id|
            @chunk_index_by_row_id[row_id] = chunk_index
          end
        end
      end

      def project_chunk(chunk_index)
        projected_files = []

        @diff.file_diffs.each do |file_diff|
          before_offset = 0
          after_offset = 0
          projected_hunks = []
          path_operation_applied_before = path_operation_applied_before?(file_diff, chunk_index)
          path_operation_applied_after = path_operation_applied_after?(file_diff, chunk_index)

          file_diff.hunks.each do |hunk|
            case hunk.kind
            when :file_operation
              projected_hunk = project_operation_hunk(hunk, chunk_index)
              projected_hunks << projected_hunk if projected_hunk
            when :binary
              projected_hunk = project_binary_hunk(hunk, chunk_index)
              projected_hunks << projected_hunk if projected_hunk
            else
              changed, projected_hunk = project_text_hunk(hunk, chunk_index, before_offset, after_offset)
              projected_hunks << projected_hunk if changed

              before_offset += applied_delta(hunk, max_chunk_index: chunk_index - 1)
              after_offset += applied_delta(hunk, max_chunk_index: chunk_index)
            end
          end

          next if projected_hunks.empty?

          metadata_lines = projected_hunks.select { |hunk| hunk.kind == :file_operation }.flat_map(&:patch_lines)
          metadata_lines = implicit_metadata_lines(file_diff, metadata_lines) if metadata_lines.empty?
          before_paths = current_paths(file_diff, path_operation_applied: path_operation_applied_before)
          after_paths = current_paths(file_diff, path_operation_applied: path_operation_applied_after)
          binary_only = projected_hunks.all? { |hunk| hunk.kind == :binary }

          projected_files << ProjectedFile.new(
            old_path: before_paths[:old_path],
            new_path: after_paths[:new_path],
            diff_git_line: build_diff_git_line(before_paths[:old_path], after_paths[:new_path]),
            metadata_lines: metadata_lines,
            hunks: projected_hunks.reject { |hunk| hunk.kind == :file_operation },
            emit_text_headers: !binary_only || emits_text_headers_for_binary?(file_diff)
          )
        end

        projected_files
      end

      private

      def project_operation_hunk(hunk, chunk_index)
        return nil unless rows_assigned_to_chunk?(hunk, chunk_index)

        ProjectedHunk.new(
          old_start: 0,
          old_count: 0,
          new_start: 0,
          new_count: 0,
          lines: [],
          kind: :file_operation,
          patch_lines: hunk.patch_lines
        )
      end

      def project_binary_hunk(hunk, chunk_index)
        return nil unless rows_assigned_to_chunk?(hunk, chunk_index)

        ProjectedHunk.new(
          old_start: 0,
          old_count: 0,
          new_start: 0,
          new_count: 0,
          lines: [],
          kind: :binary,
          patch_lines: hunk.patch_lines
        )
      end

      def project_text_hunk(hunk, chunk_index, before_offset, after_offset)
        lines = []
        changed = false
        old_count = 0
        new_count = 0

        hunk.rows.each do |row|
          visible_before = visible_in_before?(row, chunk_index)
          visible_after = visible_in_after?(row, chunk_index)
          changed ||= visible_before != visible_after

          old_count += 1 if visible_before
          new_count += 1 if visible_after
          next unless visible_before || visible_after

          prefix = if visible_before && visible_after
                     ' '
                   elsif visible_before
                     '-'
                   else
                     '+'
                   end
          lines << "#{prefix}#{row.text}"
        end

        [
          changed,
          ProjectedHunk.new(
            old_start: hunk.old_start + before_offset,
            old_count: old_count,
            new_start: hunk.new_start + after_offset,
            new_count: new_count,
            lines: lines,
            kind: :text,
            patch_lines: []
          )
        ]
      end

      def rows_assigned_to_chunk?(hunk, chunk_index)
        hunk.change_rows.all? { |row| @chunk_index_by_row_id.fetch(row.id) == chunk_index }
      end

      def applied_delta(hunk, max_chunk_index:)
        return 0 if max_chunk_index.negative?

        delta = 0
        hunk.change_rows.each do |row|
          chunk_index = @chunk_index_by_row_id.fetch(row.id)
          next if chunk_index > max_chunk_index

          delta += 1 if row.kind == :addition
          delta -= 1 if row.kind == :deletion
        end
        delta
      end

      def visible_in_before?(row, chunk_index)
        case row.kind
        when :context
          true
        when :deletion
          @chunk_index_by_row_id.fetch(row.id) >= chunk_index
        when :addition
          @chunk_index_by_row_id.fetch(row.id) < chunk_index
        else
          false
        end
      end

      def visible_in_after?(row, chunk_index)
        case row.kind
        when :context
          true
        when :deletion
          @chunk_index_by_row_id.fetch(row.id) > chunk_index
        when :addition
          @chunk_index_by_row_id.fetch(row.id) <= chunk_index
        else
          false
        end
      end

      def current_paths(file_diff, path_operation_applied:)
        operation_hunk = file_diff.path_operation_hunk
        return { old_path: file_diff.old_path, new_path: file_diff.new_path } unless operation_hunk

        if path_operation_applied
          { old_path: file_diff.new_path, new_path: file_diff.new_path }
        else
          { old_path: file_diff.old_path, new_path: file_diff.old_path }
        end
      end

      def build_diff_git_line(old_path, new_path)
        old_git_path = if old_path == '/dev/null'
                         to_git_old_path(new_path)
                       elsif new_path == '/dev/null'
                         to_git_old_path(old_path)
                       else
                         to_git_old_path(old_path)
                       end
        new_git_path = if new_path == '/dev/null'
                         to_git_new_path(old_path)
                       elsif old_path == '/dev/null'
                         to_git_new_path(new_path)
                       else
                         to_git_new_path(new_path)
                       end

        "diff --git #{old_git_path} #{new_git_path}"
      end

      def path_operation_applied_before?(file_diff, chunk_index)
        return false if chunk_index.zero?

        path_operation_applied_after?(file_diff, chunk_index - 1)
      end

      def path_operation_applied_after?(file_diff, chunk_index)
        operation_hunk = file_diff.path_operation_hunk
        return false unless operation_hunk

        operation_hunk.change_rows.all? do |row|
          @chunk_index_by_row_id.fetch(row.id) <= chunk_index
        end
      end

      def emits_text_headers_for_binary?(file_diff)
        file_diff.modification? || file_diff.path_operation_hunk
      end

      def implicit_metadata_lines(file_diff, metadata_lines)
        return metadata_lines unless file_diff.addition? || file_diff.deletion?

        file_diff.metadata_lines.select do |line|
          line.start_with?('new file mode ') || line.start_with?('deleted file mode ')
        end
      end

      def to_git_old_path(path)
        return '/dev/null' if path == '/dev/null'

        "a/#{path.sub(%r{\A[ab]/}, '')}"
      end

      def to_git_new_path(path)
        return '/dev/null' if path == '/dev/null'

        "b/#{path.sub(%r{\A[ab]/}, '')}"
      end
    end
  end
end
