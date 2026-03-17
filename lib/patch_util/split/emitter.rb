# frozen_string_literal: true

module PatchUtil
  module Split
    class Emitter
      def emit(projected_files)
        lines = []

        projected_files.each do |file_patch|
          lines << file_patch.diff_git_line if file_patch.diff_git_line
          lines.concat(file_patch.metadata_lines)
          if file_patch.emit_text_headers
            lines << "--- #{format_old_path(file_patch.old_path)}"
            lines << "+++ #{format_new_path(file_patch.new_path)}"
          end

          file_patch.hunks.each do |hunk|
            if hunk.kind == :text
              lines << "@@ -#{format_range(hunk.old_start,
                                           hunk.old_count)} +#{format_range(hunk.new_start, hunk.new_count)} @@"
              lines.concat(hunk.lines)
            else
              lines.concat(hunk.patch_lines)
            end
          end
        end

        return '' if lines.empty?

        lines.join("\n") + "\n"
      end

      private

      def format_range(start, count)
        "#{start},#{count}"
      end

      def format_old_path(path)
        return '/dev/null' if path == '/dev/null'

        "a/#{path.sub(%r{\A[ab]/}, '')}"
      end

      def format_new_path(path)
        return '/dev/null' if path == '/dev/null'

        "b/#{path.sub(%r{\A[ab]/}, '')}"
      end
    end
  end
end
