# frozen_string_literal: true

module PatchUtil
  Diff = Data.define(:source, :file_diffs) do
    def hunks
      file_diffs.flat_map(&:hunks)
    end

    def change_rows
      hunks.flat_map(&:change_rows)
    end

    def hunk_by_label(label)
      hunks.find { |hunk| hunk.label == label }
    end

    def row_by_id(row_id)
      hunks.each do |hunk|
        row = hunk.rows.find { |candidate| candidate.id == row_id }
        return row if row
      end
      nil
    end
  end

  FileDiff = Data.define(:old_path, :new_path, :hunks, :diff_git_line, :metadata_lines) do
    def modification?
      old_path != '/dev/null' && new_path != '/dev/null'
    end

    def addition?
      old_path == '/dev/null'
    end

    def deletion?
      new_path == '/dev/null'
    end

    def rename?
      metadata_lines.any? { |line| line.start_with?('rename from ') || line.start_with?('rename to ') }
    end

    def copy?
      metadata_lines.any? { |line| line.start_with?('copy from ') || line.start_with?('copy to ') }
    end

    def binary?
      hunks.any?(&:binary?)
    end

    def operation_hunks
      hunks.select(&:operation?)
    end

    def operation_hunk
      operation_hunks.first
    end

    def path_operation_hunk
      operation_hunks.find(&:path_change?)
    end

    def text_hunks
      hunks.select(&:text?)
    end
  end

  Hunk = Data.define(:label, :old_start, :old_count, :new_start, :new_count, :section, :rows, :kind, :patch_lines) do
    def change_rows
      rows.select(&:change?)
    end

    def change_lines
      lines = []
      change_rows.each do |row|
        lines << ChangeLine.new(
          label: row.change_label,
          row_id: row.id,
          kind: row.kind,
          text: row.text,
          old_lineno: row.old_lineno,
          new_lineno: row.new_lineno
        )
      end
      lines
    end

    def operation?
      kind == :file_operation
    end

    def binary?
      kind == :binary
    end

    def text?
      kind == :text
    end

    def path_change?
      patch_lines.any? do |line|
        line.start_with?('rename from ') || line.start_with?('rename to ') ||
          line.start_with?('copy from ') || line.start_with?('copy to ')
      end
    end
  end

  Row = Data.define(:id, :kind, :text, :old_lineno, :new_lineno, :change_label, :change_ordinal) do
    def change?
      !change_ordinal.nil?
    end

    def display_prefix
      case kind
      when :context
        ' '
      when :deletion
        '-'
      when :addition
        '+'
      when :file_operation
        '='
      when :binary
        '='
      else
        raise PatchUtil::UnsupportedFeatureError, "unknown row kind: #{kind.inspect}"
      end
    end
  end

  ChangeLine = Data.define(:label, :row_id, :kind, :text, :old_lineno, :new_lineno)
end
