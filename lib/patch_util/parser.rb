# frozen_string_literal: true

module PatchUtil
  class Parser
    HUNK_HEADER = /\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?: ?(.*))?\z/

    def parse(source)
      lines = source.diff_text.lines(chomp: true)
      file_diffs = []
      index = 0
      hunk_index = 0

      while index < lines.length
        index += 1 while index < lines.length && lines[index].empty?
        break if index >= lines.length

        diff_git_line = nil
        metadata_lines = []

        if lines[index].start_with?('diff --git ')
          diff_git_line = lines[index]
          index += 1

          while index < lines.length && metadata_line?(lines[index])
            metadata_lines << lines[index]
            index += 1
          end
        elsif !lines[index].start_with?('--- ')
          raise ParseError, "unsupported diff prelude line: #{lines[index]}"
        end

        if index < lines.length && lines[index].start_with?('Binary files ')
          raise UnsupportedFeatureError,
                'binary diff requires a GIT binary patch payload; plain Binary files differ output is not enough'
        end

        old_path, new_path, index = parse_paths(lines, index, metadata_lines, diff_git_line)
        hunks = []

        if index < lines.length && lines[index] == 'GIT binary patch'
          path_lines = path_metadata_lines(metadata_lines)
          if path_lines.any?
            operation_hunk, hunk_index = build_operation_hunk(
              old_path: old_path,
              new_path: new_path,
              patch_lines: path_lines,
              hunk_index: hunk_index
            )
            hunks << operation_hunk
          end

          binary_hunk, index, hunk_index = build_binary_hunk(
            lines: lines,
            index: index,
            old_path: old_path,
            new_path: new_path,
            metadata_lines: binary_metadata_lines(metadata_lines),
            hunk_index: hunk_index
          )
          hunks << binary_hunk
        else
          operation_lines = nonbinary_operation_lines(metadata_lines)
          if operation_lines.any?
            operation_hunk, hunk_index = build_operation_hunk(
              old_path: old_path,
              new_path: new_path,
              patch_lines: operation_lines,
              hunk_index: hunk_index
            )
            hunks << operation_hunk
          end

          while index < lines.length && lines[index].start_with?('@@ ')
            hunk, index = parse_text_hunk(lines, index, hunk_index)
            hunks << hunk
            hunk_index += 1
          end
        end

        raise UnsupportedFeatureError, "file diff for #{new_path} has no supported hunks" if hunks.empty?

        file_diffs << FileDiff.new(
          old_path: old_path,
          new_path: new_path,
          hunks: hunks,
          diff_git_line: diff_git_line,
          metadata_lines: metadata_lines
        )
      end

      Diff.new(source: source, file_diffs: file_diffs)
    end

    private

    def parse_paths(lines, index, metadata_lines, diff_git_line)
      if index < lines.length && lines[index].start_with?('--- ')
        old_path = lines[index].delete_prefix('--- ')
        index += 1
        new_line = lines[index]
        raise ParseError, "missing +++ header after #{old_path}" unless new_line&.start_with?('+++ ')

        new_path = new_line.delete_prefix('+++ ')
        index += 1
        return [old_path, new_path, index]
      end

      rename_from = metadata_value(metadata_lines, 'rename from ')
      rename_to = metadata_value(metadata_lines, 'rename to ')
      copy_from = metadata_value(metadata_lines, 'copy from ')
      copy_to = metadata_value(metadata_lines, 'copy to ')
      old_path_from_diff, new_path_from_diff = diff_git_line ? paths_from_diff_git_line(diff_git_line) : [nil, nil]

      return ["a/#{rename_from}", "b/#{rename_to}", index] if rename_from && rename_to
      return ["a/#{copy_from}", "b/#{copy_to}", index] if copy_from && copy_to

      return ['/dev/null', new_path_from_diff, index] if metadata_value(metadata_lines, 'new file mode ')

      return [old_path_from_diff, '/dev/null', index] if metadata_value(metadata_lines, 'deleted file mode ')

      return [*paths_from_diff_git_line(diff_git_line), index] if diff_git_line

      raise ParseError, 'missing path headers and no diff --git or rename/copy metadata to infer paths'
    end

    def metadata_line?(line)
      line.start_with?('index ') ||
        line.start_with?('old mode ') ||
        line.start_with?('new mode ') ||
        line.start_with?('deleted file mode ') ||
        line.start_with?('new file mode ') ||
        line.start_with?('similarity index ') ||
        line.start_with?('rename from ') ||
        line.start_with?('rename to ') ||
        line.start_with?('copy from ') ||
        line.start_with?('copy to ')
    end

    def path_metadata_lines(metadata_lines)
      metadata_lines.select do |line|
        line.start_with?('similarity index ') ||
          line.start_with?('rename from ') ||
          line.start_with?('rename to ') ||
          line.start_with?('copy from ') ||
          line.start_with?('copy to ')
      end
    end

    def mode_metadata_lines(metadata_lines)
      metadata_lines.select do |line|
        line.start_with?('old mode ') ||
          line.start_with?('new mode ')
      end
    end

    def nonbinary_operation_lines(metadata_lines)
      metadata_lines.select do |line|
        line.start_with?('old mode ') ||
          line.start_with?('new mode ') ||
          line.start_with?('similarity index ') ||
          line.start_with?('rename from ') ||
          line.start_with?('rename to ') ||
          line.start_with?('copy from ') ||
          line.start_with?('copy to ')
      end
    end

    def binary_metadata_lines(metadata_lines)
      metadata_lines.reject do |line|
        line.start_with?('similarity index ') ||
          line.start_with?('rename from ') ||
          line.start_with?('rename to ') ||
          line.start_with?('copy from ') ||
          line.start_with?('copy to ')
      end
    end

    def build_operation_hunk(old_path:, new_path:, patch_lines:, hunk_index:)
      label = hunk_label_for(hunk_index)
      row = Row.new(
        id: "#{label}:0",
        kind: :file_operation,
        text: operation_summary(old_path: old_path, new_path: new_path, patch_lines: patch_lines),
        old_lineno: nil,
        new_lineno: nil,
        change_label: "#{label}1",
        change_ordinal: 1
      )

      [
        Hunk.new(
          label: label,
          old_start: 0,
          old_count: 0,
          new_start: 0,
          new_count: 0,
          section: "file operation #{old_path} -> #{new_path}",
          rows: [row],
          kind: :file_operation,
          patch_lines: patch_lines
        ),
        hunk_index + 1
      ]
    end

    def build_binary_hunk(lines:, index:, old_path:, new_path:, metadata_lines:, hunk_index:)
      label = hunk_label_for(hunk_index)
      payload_lines = []

      while index < lines.length
        break if lines[index].start_with?('diff --git ')

        payload_lines << lines[index]
        index += 1
      end

      patch_lines = metadata_lines + payload_lines
      row = Row.new(
        id: "#{label}:0",
        kind: :binary,
        text: binary_summary(old_path: old_path, new_path: new_path, patch_lines: patch_lines),
        old_lineno: nil,
        new_lineno: nil,
        change_label: "#{label}1",
        change_ordinal: 1
      )

      [
        Hunk.new(
          label: label,
          old_start: 0,
          old_count: 0,
          new_start: 0,
          new_count: 0,
          section: "binary change #{old_path} -> #{new_path}",
          rows: [row],
          kind: :binary,
          patch_lines: patch_lines
        ),
        index,
        hunk_index + 1
      ]
    end

    def parse_text_hunk(lines, start_index, hunk_index)
      header = lines[start_index]
      match = HUNK_HEADER.match(header)
      raise ParseError, "invalid hunk header: #{header}" unless match

      old_start = Integer(match[1], 10)
      old_count = match[2] ? Integer(match[2], 10) : 1
      new_start = Integer(match[3], 10)
      new_count = match[4] ? Integer(match[4], 10) : 1
      section = match[5]

      rows = []
      index = start_index + 1
      old_lineno = old_start
      new_lineno = new_start
      change_ordinal = 0
      row_index = 0
      hunk_label = hunk_label_for(hunk_index)

      while index < lines.length
        line = lines[index]
        break if line.start_with?('@@ ') || line.start_with?('diff --git ') || line.start_with?('--- ')
        break if metadata_line?(line) || line == 'GIT binary patch' || line.start_with?('Binary files ')

        if line == '\ No newline at end of file'
          index += 1
          next
        end

        prefix = line[0]
        text = line[1..] || ''
        row_id = "#{hunk_label}:#{row_index}"

        case prefix
        when ' '
          rows << Row.new(
            id: row_id,
            kind: :context,
            text: text,
            old_lineno: old_lineno,
            new_lineno: new_lineno,
            change_label: nil,
            change_ordinal: nil
          )
          old_lineno += 1
          new_lineno += 1
        when '-'
          change_ordinal += 1
          rows << Row.new(
            id: row_id,
            kind: :deletion,
            text: text,
            old_lineno: old_lineno,
            new_lineno: nil,
            change_label: "#{hunk_label}#{change_ordinal}",
            change_ordinal: change_ordinal
          )
          old_lineno += 1
        when '+'
          change_ordinal += 1
          rows << Row.new(
            id: row_id,
            kind: :addition,
            text: text,
            old_lineno: nil,
            new_lineno: new_lineno,
            change_label: "#{hunk_label}#{change_ordinal}",
            change_ordinal: change_ordinal
          )
          new_lineno += 1
        else
          raise ParseError, "unsupported hunk row: #{line}"
        end

        row_index += 1
        index += 1
      end

      [
        Hunk.new(
          label: hunk_label,
          old_start: old_start,
          old_count: old_count,
          new_start: new_start,
          new_count: new_count,
          section: section,
          rows: rows,
          kind: :text,
          patch_lines: []
        ),
        index
      ]
    end

    def metadata_value(metadata_lines, prefix)
      line = metadata_lines.find { |item| item.start_with?(prefix) }
      return nil unless line

      line.delete_prefix(prefix)
    end

    def operation_summary(old_path:, new_path:, patch_lines:)
      old_mode = metadata_value(patch_lines, 'old mode ')
      new_mode = metadata_value(patch_lines, 'new mode ')
      rename_from = metadata_value(patch_lines, 'rename from ')
      copy_from = metadata_value(patch_lines, 'copy from ')
      similarity = metadata_value(patch_lines, 'similarity index ')

      operation_parts = []
      if rename_from
        text = "rename #{display_path(old_path)} -> #{display_path(new_path)}"
        text += " (#{similarity})" if similarity
        operation_parts << text
      elsif copy_from
        text = "copy #{display_path(old_path)} -> #{display_path(new_path)}"
        text += " (#{similarity})" if similarity
        operation_parts << text
      end

      operation_parts << "mode #{display_path(new_path)} #{old_mode} -> #{new_mode}" if old_mode && new_mode

      return operation_parts.join(', ') if operation_parts.any?

      "file operation #{display_path(old_path)} -> #{display_path(new_path)}"
    end

    def binary_summary(old_path:, new_path:, patch_lines:)
      old_mode = metadata_value(patch_lines, 'old mode ')
      new_mode = metadata_value(patch_lines, 'new mode ')

      summary = if old_path == '/dev/null'
                  "binary add #{display_path(new_path)}"
                elsif new_path == '/dev/null'
                  "binary delete #{display_path(old_path)}"
                else
                  "binary #{display_path(new_path)}"
                end
      summary += " (mode #{old_mode} -> #{new_mode})" if old_mode && new_mode
      summary
    end

    def display_path(path)
      return path if path == '/dev/null'

      path.sub(%r{\A[ab]/}, '')
    end

    def paths_from_diff_git_line(diff_git_line)
      match = /\Adiff --git (\S+) (\S+)\z/.match(diff_git_line.to_s)
      raise ParseError, 'missing diff --git header needed to infer diff paths' unless match

      [match[1], match[2]]
    end

    def hunk_label_for(index)
      current = index
      label = +''

      loop do
        label.prepend((97 + (current % 26)).chr)
        current = (current / 26) - 1
        break if current.negative?
      end

      label
    end
  end
end
