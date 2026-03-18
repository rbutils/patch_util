# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'shellwords'

module PatchUtil
  module Git
    class Cli
      ConflictMarkerDetail = Data.define(:path, :marker_count, :first_marker_line, :excerpt)
      ConflictBlockDetail = Data.define(:path, :block_id, :start_line, :end_line, :ours, :theirs, :ancestor, :excerpt)
      CommitMetadata = Data.define(:subject, :body,
                                   :author_name, :author_email, :author_date,
                                   :committer_name, :committer_email, :committer_date)

      def inside_repo?(path)
        _stdout, _stderr, status = run(path, %w[rev-parse --is-inside-work-tree], raise_on_error: false)
        status.success?
      end

      def repo_root(path)
        stdout, = run(path, %w[rev-parse --show-toplevel])
        stdout.strip
      end

      def git_dir(path)
        stdout, = run(path, %w[rev-parse --absolute-git-dir])
        stdout.strip
      end

      def rev_parse(path, revision)
        stdout, = run(path, ['rev-parse', revision])
        stdout.strip
      end

      def show_commit_patch(path, revision)
        stdout, = run(path, ['show', '--binary', '--format=', '--no-ext-diff', revision, '--'])
        stdout
      end

      def parent_shas(path, revision)
        stdout, = run(path, ['rev-list', '--parents', '-n', '1', revision])
        parts = stdout.strip.split(' ')
        parts.drop(1)
      end

      def merge_commit?(path, revision)
        parent_shas(path, revision).length > 1
      end

      def show_subject(path, revision)
        stdout, = run(path, ['show', '-s', '--format=%s', revision])
        stdout.strip
      end

      def show_commit_metadata(path, revision)
        stdout, = run(path, ['show', '-s', '--format=%s%x00%b%x00%an%x00%ae%x00%aI%x00%cn%x00%ce%x00%cI', revision])
        subject, body, author_name, author_email, author_date,
          committer_name, committer_email, committer_date = stdout.split("\0", 8)

        CommitMetadata.new(
          subject: subject,
          body: (body || '').sub(/\n\z/, ''),
          author_name: author_name,
          author_email: author_email,
          author_date: author_date.to_s.strip,
          committer_name: committer_name,
          committer_email: committer_email,
          committer_date: committer_date.to_s.strip
        )
      end

      def head_sha(path)
        rev_parse(path, 'HEAD')
      end

      def current_branch(path)
        stdout, = run(path, %w[branch --show-current])
        stdout.strip
      end

      def worktree_clean?(path)
        stdout, = run(path, %w[status --porcelain])
        stdout.strip.empty?
      end

      def ancestor?(path, ancestor, descendant)
        _stdout, _stderr, status = run(path, ['merge-base', '--is-ancestor', ancestor, descendant],
                                       raise_on_error: false)
        status.success?
      end

      def rev_list(path, revision_range)
        stdout, = run(path, ['rev-list', '--reverse', revision_range])
        stdout.lines(chomp: true)
      end

      def worktree_add(path, worktree_path, revision)
        run(path, ['worktree', 'add', '--detach', File.expand_path(worktree_path), revision])
      end

      def worktree_remove(path, worktree_path)
        run(path, ['worktree', 'remove', '--force', File.expand_path(worktree_path)])
      end

      def apply_patch_text(path, patch_text)
        stdout, stderr, status = Open3.capture3('git', '-C', File.expand_path(path), 'apply', '--whitespace=nowarn',
                                                '-', stdin_data: patch_text)
        raise PatchUtil::Error, "git apply failed: #{stderr.strip}" unless status.success?

        stdout
      end

      def check_patch_text(path, patch_text)
        stdout, stderr, status = Open3.capture3('git', '-C', File.expand_path(path), 'apply', '--check',
                                                '--whitespace=nowarn', '-', stdin_data: patch_text)
        raise PatchUtil::Error, "git apply --check failed: #{stderr.strip}" unless status.success?

        stdout
      end

      def commit_all(path, message, env: {})
        add_stdout, add_stderr, add_status = Open3.capture3(env, 'git', '-C', File.expand_path(path), 'add', '-A')
        raise PatchUtil::Error, "git add failed: #{add_stderr.strip}" unless add_status.success?

        stdout, stderr, status = Open3.capture3(env, 'git', '-C', File.expand_path(path), 'commit', '-m', message)
        raise PatchUtil::Error, "git commit failed: #{stderr.strip}" unless status.success?

        add_stdout + stdout
      end

      def cherry_pick(path, revision, env: {})
        stdout, stderr, status = Open3.capture3(env, 'git', '-C', File.expand_path(path), 'cherry-pick', revision)
        raise PatchUtil::Error, "git cherry-pick failed for #{revision}: #{stderr.strip}" unless status.success?

        stdout
      end

      def cherry_pick_continue(path, env: {})
        stdout, stderr, status = Open3.capture3(env, 'git', '-C', File.expand_path(path), 'cherry-pick', '--continue')
        raise PatchUtil::Error, "git cherry-pick --continue failed: #{stderr.strip}" unless status.success?

        stdout
      end

      def cherry_pick_in_progress?(path)
        _stdout, _stderr, status = run(path, %w[rev-parse -q --verify CHERRY_PICK_HEAD], raise_on_error: false)
        status.success?
      end

      def cherry_pick_head(path)
        rev_parse(path, 'CHERRY_PICK_HEAD')
      end

      def unresolved_paths(path)
        stdout, = run(path, %w[diff --name-only --diff-filter=U])
        stdout.lines(chomp: true)
      end

      def conflict_marker_details(path, file_paths: nil)
        worktree_path = File.expand_path(path)
        details = []

        candidate_paths(worktree_path, file_paths).each do |relative_path|
          absolute_path = File.join(worktree_path, relative_path)
          next unless File.file?(absolute_path)

          detail = conflict_marker_detail(relative_path, absolute_path)
          details << detail if detail
        end

        details.sort_by(&:path)
      end

      def conflict_block_details(path, file_paths: nil)
        worktree_path = File.expand_path(path)
        details = []

        candidate_paths(worktree_path, file_paths).each do |relative_path|
          absolute_path = File.join(worktree_path, relative_path)
          next unless File.file?(absolute_path)

          details.concat(conflict_blocks_for_file(relative_path, absolute_path))
        end

        details.sort_by { |detail| [detail.path, detail.block_id] }
      end

      def resolve_conflict_block(path, file_path:, block_id:, side:)
        raise PatchUtil::ValidationError, "unsupported conflict side: #{side}" unless %w[ours theirs
                                                                                         ancestor].include?(side)

        worktree_path = File.expand_path(path)
        absolute_path = File.join(worktree_path, file_path)
        blocks = conflict_blocks_for_file(file_path, absolute_path)
        block = blocks.find { |candidate| candidate.block_id == block_id }
        raise PatchUtil::ValidationError, "unknown conflict block #{block_id} for #{file_path}" unless block

        lines = File.readlines(absolute_path, chomp: true)
        replacement = case side
                      when 'ours'
                        block.ours
                      when 'theirs'
                        block.theirs
                      when 'ancestor'
                        if block.ancestor.empty?
                          raise PatchUtil::ValidationError,
                                "conflict block #{block_id} for #{file_path} has no ancestor section"
                        end

                        block.ancestor
                      end
        replacement_lines = replacement.empty? ? [] : replacement.split("\n", -1)
        updated_lines = lines[0...(block.start_line - 1)] + replacement_lines + lines[block.end_line..]
        File.write(absolute_path, updated_lines.join("\n") + "\n")

        remaining_blocks = conflict_blocks_for_file(file_path, absolute_path)
        add_paths(path, [file_path]) if remaining_blocks.empty?

        {
          remaining_blocks: remaining_blocks,
          staged: remaining_blocks.empty?
        }
      end

      def export_conflict_block_template(path, file_path:, block_id:, output_path:)
        worktree_path = File.expand_path(path)
        absolute_path = File.join(worktree_path, file_path)
        blocks = conflict_blocks_for_file(file_path, absolute_path)
        block = blocks.find { |candidate| candidate.block_id == block_id }
        raise PatchUtil::ValidationError, "unknown conflict block #{block_id} for #{file_path}" unless block

        target_path = File.expand_path(output_path)
        FileUtils.mkdir_p(File.dirname(target_path))
        File.write(target_path, conflict_block_template(block))
        target_path
      end

      def apply_conflict_block_edit(path, file_path:, block_id:, input_path:)
        template_text = File.read(File.expand_path(input_path))
        metadata = extract_template_metadata(template_text)
        validate_template_metadata(metadata, expected_path: file_path, expected_block_id: block_id)
        replacement = extract_editable_content(template_text)
        resolve_conflict_block_with_text(path, file_path: file_path, block_id: block_id, replacement: replacement)
      end

      def export_conflict_block_session_template(path, output_path:, file_paths: nil)
        blocks = conflict_block_details(path, file_paths: file_paths)
        raise PatchUtil::ValidationError, 'no conflict blocks found for export' if blocks.empty?

        target_path = File.expand_path(output_path)
        FileUtils.mkdir_p(File.dirname(target_path))
        File.write(target_path, conflict_block_session_template(blocks))
        {
          output_path: target_path,
          blocks: blocks
        }
      end

      def apply_conflict_block_session_edit(path, input_path:)
        template_text = File.read(File.expand_path(input_path))
        session_metadata = extract_session_metadata(template_text)
        validate_session_template_metadata(session_metadata)
        entries = extract_session_block_entries(template_text)
        raise PatchUtil::ValidationError, 'edited block session template contains no blocks' if entries.empty?

        validate_session_block_entries(entries, expected_block_count: session_metadata[:block_count])
        preflight_session_block_entries(path, entries)

        results = []
        grouped_entries = entries.group_by { |entry| entry[:path] }
        grouped_entries.keys.sort.each do |file_path|
          file_entries = grouped_entries.fetch(file_path)
          file_entries.sort_by { |entry| -entry[:block_id] }.each do |entry|
            result = resolve_conflict_block_with_text(path, file_path: entry[:path], block_id: entry[:block_id],
                                                            replacement: entry[:replacement])
            results << entry.merge(remaining_blocks: result[:remaining_blocks], staged: result[:staged])
          end
        end

        {
          applied_blocks: results.sort_by { |entry| [entry[:path], entry[:block_id]] },
          remaining_blocks_by_file: results.each_with_object({}) do |entry, acc|
            acc[entry[:path]] = entry[:remaining_blocks]
          end,
          staged_paths: results.select { |entry| entry[:staged] }.map { |entry| entry[:path] }.uniq.sort
        }
      end

      def checkout_conflict_side(path, side, file_paths)
        raise PatchUtil::ValidationError, "unsupported conflict side: #{side}" unless %w[ours theirs].include?(side)

        run(path, ['checkout', "--#{side}", '--', *file_paths])
      end

      def add_paths(path, file_paths)
        run(path, ['add', '--', *file_paths])
      end

      def update_ref(path, ref, new_oid, old_oid = nil)
        args = ['update-ref', ref, new_oid]
        args << old_oid if old_oid
        run(path, args)
      end

      def reset_hard(path, revision)
        run(path, ['reset', '--hard', revision])
      end

      private

      def candidate_paths(worktree_path, file_paths)
        return file_paths.uniq if file_paths && !file_paths.empty?

        glob = File.join(worktree_path, '**', '*')
        Dir.glob(glob, File::FNM_DOTMATCH).filter_map do |absolute_path|
          next if File.directory?(absolute_path)

          relative_path = absolute_path.delete_prefix("#{worktree_path}/")
          next if relative_path.start_with?('.git/') || relative_path == '.git'

          relative_path
        end
      end

      def conflict_marker_detail(relative_path, absolute_path)
        lines = File.readlines(absolute_path, chomp: true)
        marker_indexes = []
        lines.each_with_index do |line, index|
          marker_indexes << index if line.start_with?('<<<<<<< ')
        end
        return nil if marker_indexes.empty?

        first_index = marker_indexes.first
        end_index = find_conflict_end(lines, first_index)
        excerpt_start = [first_index - 1, 0].max
        excerpt_end = [end_index + 1, lines.length - 1].min

        ConflictMarkerDetail.new(
          path: relative_path,
          marker_count: marker_indexes.length,
          first_marker_line: first_index + 1,
          excerpt: lines[excerpt_start..excerpt_end].join("\n")
        )
      rescue Errno::ENOENT, EncodingError
        nil
      end

      def find_conflict_end(lines, start_index)
        index = start_index
        while index < lines.length
          return index if lines[index].start_with?('>>>>>>> ')

          index += 1
        end

        lines.length - 1
      end

      def conflict_blocks_for_file(relative_path, absolute_path)
        lines = File.readlines(absolute_path, chomp: true)
        index = 0
        block_id = 1
        blocks = []

        while index < lines.length
          unless lines[index].start_with?('<<<<<<< ')
            index += 1
            next
          end

          start_index = index
          ancestor_index = nil
          separator_index = nil
          end_index = nil
          cursor = index + 1

          while cursor < lines.length
            line = lines[cursor]
            ancestor_index ||= cursor if line.start_with?('||||||| ')
            separator_index ||= cursor if line == '======='
            if line.start_with?('>>>>>>> ')
              end_index = cursor
              break
            end
            cursor += 1
          end

          break unless separator_index && end_index

          ours_start = start_index + 1
          ours_end = (ancestor_index || separator_index) - 1
          theirs_start = separator_index + 1
          theirs_end = end_index - 1
          ancestor = if ancestor_index
                       ancestor_start = ancestor_index + 1
                       ancestor_end = separator_index - 1
                       slice(lines, ancestor_start, ancestor_end)
                     else
                       ''
                     end

          blocks << ConflictBlockDetail.new(
            path: relative_path,
            block_id: block_id,
            start_line: start_index + 1,
            end_line: end_index + 1,
            ours: slice(lines, ours_start, ours_end),
            theirs: slice(lines, theirs_start, theirs_end),
            ancestor: ancestor,
            excerpt: lines[start_index..end_index].join("\n")
          )

          block_id += 1
          index = end_index + 1
        end

        blocks
      rescue Errno::ENOENT, EncodingError
        []
      end

      def slice(lines, start_index, end_index)
        return '' if end_index < start_index

        lines[start_index..end_index].join("\n")
      end

      def resolve_conflict_block_with_text(path, file_path:, block_id:, replacement:)
        worktree_path = File.expand_path(path)
        absolute_path = File.join(worktree_path, file_path)
        blocks = conflict_blocks_for_file(file_path, absolute_path)
        block = blocks.find { |candidate| candidate.block_id == block_id }
        raise PatchUtil::ValidationError, "unknown conflict block #{block_id} for #{file_path}" unless block

        lines = File.readlines(absolute_path, chomp: true)
        replacement_lines = replacement.empty? ? [] : replacement.split("\n", -1)
        updated_lines = lines[0...(block.start_line - 1)] + replacement_lines + lines[block.end_line..]
        File.write(absolute_path, updated_lines.join("\n") + "\n")

        remaining_blocks = conflict_blocks_for_file(file_path, absolute_path)
        add_paths(path, [file_path]) if remaining_blocks.empty?

        {
          remaining_blocks: remaining_blocks,
          staged: remaining_blocks.empty?
        }
      end

      def conflict_block_template(block)
        sections = []
        sections << '# patch_util retained conflict block edit template'
        sections << '# format: patch_util-conflict-block-v1'
        sections << "# path: #{block.path}"
        sections << "# block id: #{block.block_id}"
        sections << '# Edit only the content between BEGIN/END EDIT.'
        sections << '### BEGIN EDIT ###'
        sections << block.ours
        sections << '### END EDIT ###'
        sections << '### OURS ###'
        sections << block.ours
        sections << '### END OURS ###'
        unless block.ancestor.empty?
          sections << '### ANCESTOR ###'
          sections << block.ancestor
          sections << '### END ANCESTOR ###'
        end
        sections << '### THEIRS ###'
        sections << block.theirs
        sections << '### END THEIRS ###'
        sections << '### EXCERPT ###'
        sections << block.excerpt
        sections << '### END EXCERPT ###'
        sections.join("\n") + "\n"
      end

      def conflict_block_session_template(blocks)
        sections = []
        sections << '# patch_util retained conflict block edit session template'
        sections << '# format: patch_util-conflict-session-v1'
        sections << "# block count: #{blocks.length}"
        blocks.each do |block|
          sections << '### BLOCK START ###'
          sections << "# path: #{block.path}"
          sections << "# block id: #{block.block_id}"
          sections << '# Edit only the content between BEGIN/END EDIT.'
          sections << '### BEGIN EDIT ###'
          sections << block.ours
          sections << '### END EDIT ###'
          sections << '### OURS ###'
          sections << block.ours
          sections << '### END OURS ###'
          unless block.ancestor.empty?
            sections << '### ANCESTOR ###'
            sections << block.ancestor
            sections << '### END ANCESTOR ###'
          end
          sections << '### THEIRS ###'
          sections << block.theirs
          sections << '### END THEIRS ###'
          sections << '### EXCERPT ###'
          sections << block.excerpt
          sections << '### END EXCERPT ###'
          sections << '### BLOCK END ###'
        end
        sections.join("\n") + "\n"
      end

      def extract_editable_content(text)
        lines = text.lines(chomp: true)
        begin_index = lines.index('### BEGIN EDIT ###')
        end_index = lines.index('### END EDIT ###')
        if begin_index.nil?
          raise PatchUtil::ValidationError,
                'edited block template is missing ### BEGIN EDIT ### marker'
        end
        raise PatchUtil::ValidationError, 'edited block template is missing ### END EDIT ### marker' if end_index.nil?

        if end_index < begin_index
          raise PatchUtil::ValidationError,
                'edited block template has END EDIT before BEGIN EDIT'
        end

        lines[(begin_index + 1)...end_index].join("\n")
      end

      def extract_template_metadata(text)
        metadata = {}
        text.lines(chomp: true).each do |line|
          metadata[:format] = line.delete_prefix('# format: ').strip if line.start_with?('# format: ')
          metadata[:path] = line.delete_prefix('# path: ').strip if line.start_with?('# path: ')
          if line.start_with?('# block id: ')
            raw = line.delete_prefix('# block id: ').strip
            metadata[:block_id] = Integer(raw, 10)
          end
        rescue ArgumentError
          raise PatchUtil::ValidationError, "edited block template has invalid block id: #{raw.inspect}"
        end
        metadata
      end

      def extract_session_metadata(text)
        metadata = {}
        text.lines(chomp: true).each do |line|
          metadata[:format] = line.delete_prefix('# format: ').strip if line.start_with?('# format: ')
          if line.start_with?('# block count: ')
            raw = line.delete_prefix('# block count: ').strip
            metadata[:block_count] = Integer(raw, 10)
          end
        rescue ArgumentError
          raise PatchUtil::ValidationError, "edited block session template has invalid block count: #{raw.inspect}"
        end
        metadata
      end

      def validate_session_template_metadata(metadata)
        unless metadata[:format] == 'patch_util-conflict-session-v1'
          raise PatchUtil::ValidationError,
                'edited block session template is missing or has unknown # format metadata'
        end

        return if metadata.key?(:block_count)

        raise PatchUtil::ValidationError,
              'edited block session template is missing # block count metadata'
      end

      def validate_session_block_entries(entries, expected_block_count:)
        if entries.length != expected_block_count
          raise PatchUtil::ValidationError,
                "edited block session template declares #{expected_block_count} blocks but contains #{entries.length} blocks"
        end

        duplicates = entries.group_by { |entry| [entry[:path], entry[:block_id]] }
                            .select { |_identity, grouped_entries| grouped_entries.length > 1 }
        return if duplicates.empty?

        path, block_id = duplicates.keys.sort.first
        raise PatchUtil::ValidationError,
              "edited block session template repeats block #{block_id} for #{path}"
      end

      def preflight_session_block_entries(path, entries)
        selected_paths = entries.map { |entry| entry[:path] }.uniq
        available_blocks = conflict_block_details(path,
                                                  file_paths: selected_paths).each_with_object({}) do |block, index|
          index[[block.path, block.block_id]] = true
        end

        entries.each do |entry|
          next if available_blocks[[entry[:path], entry[:block_id]]]

          raise PatchUtil::ValidationError,
                "edited block session template references missing block #{entry[:block_id]} for #{entry[:path]}"
        end
      end

      def extract_session_block_entries(text)
        lines = text.lines(chomp: true)
        entries = []
        index = 0

        while index < lines.length
          unless lines[index] == '### BLOCK START ###'
            index += 1
            next
          end

          end_index = lines[(index + 1)..]&.index('### BLOCK END ###')
          if end_index.nil?
            raise PatchUtil::ValidationError,
                  'edited block session template is missing ### BLOCK END ### marker'
          end

          section_lines = lines[(index + 1)...(index + 1 + end_index)]
          section_text = section_lines.join("\n")
          metadata = extract_template_metadata(section_text)
          unless metadata.key?(:path)
            raise PatchUtil::ValidationError,
                  'edited block session block is missing # path metadata'
          end

          unless metadata.key?(:block_id)
            raise PatchUtil::ValidationError,
                  'edited block session block is missing # block id metadata'
          end

          entries << {
            path: metadata[:path],
            block_id: metadata[:block_id],
            replacement: extract_editable_content(section_text)
          }
          index += end_index + 2
        end

        entries
      end

      def validate_template_metadata(metadata, expected_path:, expected_block_id:)
        unless metadata[:format] == 'patch_util-conflict-block-v1'
          raise PatchUtil::ValidationError,
                'edited block template is missing or has unknown # format metadata'
        end
        raise PatchUtil::ValidationError, 'edited block template is missing # path metadata' unless metadata.key?(:path)

        unless metadata[:path] == expected_path
          raise PatchUtil::ValidationError,
                "edited block template path #{metadata[:path].inspect} does not match requested path #{expected_path.inspect}"
        end
        unless metadata.key?(:block_id)
          raise PatchUtil::ValidationError,
                'edited block template is missing # block id metadata'
        end

        return if metadata[:block_id] == expected_block_id

        raise PatchUtil::ValidationError,
              "edited block template block id #{metadata[:block_id]} does not match requested block #{expected_block_id}"
      end

      def run(path, args, raise_on_error: true)
        command = ['git', '-C', File.expand_path(path), *args]
        stdout, stderr, status = Open3.capture3(*command)
        if raise_on_error && !status.success?
          raise PatchUtil::Error, "git command failed: #{command.join(' ')}\n#{stderr.strip}"
        end

        [stdout, stderr, status]
      end
    end
  end
end
