# frozen_string_literal: true

require 'thor'

module PatchUtil
  module Git
    class RewriteCLI < Thor
      desc 'abort', 'Remove retained failed rewrite worktree and clear rewrite state'
      option :repo, type: :string, aliases: '-r', banner: 'PATH'
      def abort
        repo_path = options[:repo] || Dir.pwd
        git_cli = PatchUtil::Git::Cli.new
        raise ValidationError, 'rewrite abort requires a git repository' unless git_cli.inside_repo?(repo_path)

        result = PatchUtil::Git::RewriteSessionManager.new.abort_rewrite(repo_path: repo_path)
        if result.worktree_removed
          puts "removed retained worktree #{result.worktree_path}"
        else
          puts "retained worktree already absent #{result.worktree_path}"
        end
        puts "backup ref remains at #{result.backup_ref}"
      end

      desc 'continue', 'Resume a retained failed rewrite worktree'
      option :repo, type: :string, aliases: '-r', banner: 'PATH'
      def continue
        repo_path = options[:repo] || Dir.pwd
        git_cli = PatchUtil::Git::Cli.new
        raise ValidationError, 'rewrite continue requires a git repository' unless git_cli.inside_repo?(repo_path)

        result = PatchUtil::Git::RewriteSessionManager.new.continue_rewrite(repo_path: repo_path)
        puts "rewrote #{result.branch}: #{result.old_head} -> #{result.new_head}"
        puts "backup ref: #{result.backup_ref}"
        puts 'resumed retained rewrite state'
      end

      desc 'restore', 'Restore the current branch from the recorded rewrite backup ref'
      option :repo, type: :string, aliases: '-r', banner: 'PATH'
      def restore
        repo_path = options[:repo] || Dir.pwd
        git_cli = PatchUtil::Git::Cli.new
        raise ValidationError, 'rewrite restore requires a git repository' unless git_cli.inside_repo?(repo_path)

        result = PatchUtil::Git::RewriteSessionManager.new.restore_rewrite(repo_path: repo_path)
        puts "restored #{result.branch}: #{result.old_head} -> #{result.restored_head}"
        if result.worktree_removed
          puts "removed retained worktree #{result.worktree_path}"
        else
          puts "retained worktree already absent #{result.worktree_path}"
        end
        puts "backup ref remains at #{result.backup_ref}"
      end

      desc 'status', 'Show retained rewrite state for the current branch'
      option :repo, type: :string, aliases: '-r', banner: 'PATH'
      def status
        repo_path = options[:repo] || Dir.pwd
        git_cli = PatchUtil::Git::Cli.new
        raise ValidationError, 'rewrite status requires a git repository' unless git_cli.inside_repo?(repo_path)

        branch = git_cli.current_branch(repo_path)
        raise ValidationError, 'rewrite status requires a checked out branch' if branch.empty?

        manager = PatchUtil::Git::RewriteSessionManager.new
        status = manager.status(repo_path: repo_path)
        unless status
          puts "no retained rewrite state for branch #{branch}"
          return
        end

        puts "branch: #{status.branch}"
        puts "target commit: #{status.state.target_sha}"
        puts "recorded head: #{status.state.head_sha}"
        puts "current head: #{status.head_sha}"
        puts "backup ref: #{status.state.backup_ref}"
        puts "retained worktree: #{status.state.worktree_path}"
        puts "last error: #{status.state.message}"
        puts "worktree exists: #{status.worktree_exists}"
        puts "worktree clean: #{status.worktree_clean.nil? ? 'unknown' : status.worktree_clean}"
        puts "unresolved paths: #{status.unresolved_paths.length}"
        puts "unresolved path list: #{status.unresolved_paths.join(', ')}" if status.unresolved_paths.any?
        puts "conflict marker files: #{status.conflict_marker_details.length}"
        if status.conflict_marker_details.any?
          puts "conflict marker file list: #{status.conflict_marker_details.map(&:path).join(', ')}"
        end
        puts "pending revisions: #{status.state.pending_revisions.length}"
        if status.state.pending_revisions.any?
          puts "pending revision list: #{status.state.pending_revisions.join(', ')}"
        end
        puts "current revision: #{status.current_revision}" if status.current_revision
        puts "branch head matches recorded state: #{status.head_matches}"
        puts "next action: #{manager.next_action(status)}"
      end

      desc 'conflicts', 'Show retained conflict-marker excerpts for the current branch'
      option :repo, type: :string, aliases: '-r', banner: 'PATH'
      def conflicts
        repo_path = options[:repo] || Dir.pwd
        git_cli = PatchUtil::Git::Cli.new
        raise ValidationError, 'rewrite conflicts requires a git repository' unless git_cli.inside_repo?(repo_path)

        branch = git_cli.current_branch(repo_path)
        raise ValidationError, 'rewrite conflicts requires a checked out branch' if branch.empty?

        status = PatchUtil::Git::RewriteSessionManager.new.status(repo_path: repo_path)
        unless status
          puts "no retained rewrite state for branch #{branch}"
          return
        end

        if status.conflict_marker_details.empty?
          puts 'no conflict markers found in the retained worktree'
          return
        end

        conflict_blocks = git_cli.conflict_block_details(status.state.worktree_path,
                                                         file_paths: status.conflict_marker_details.map(&:path))

        status.conflict_marker_details.each do |detail|
          puts "path: #{detail.path}"
          puts "marker count: #{detail.marker_count}"
          puts "first marker line: #{detail.first_marker_line}"
          blocks = conflict_blocks.select { |block| block.path == detail.path }
          puts "block ids: #{blocks.map(&:block_id).join(', ')}" if blocks.any?
          puts detail.excerpt
          puts '--'
        end
      end

      desc 'conflict-blocks', 'Show retained conflict blocks with separate side bodies'
      option :repo, type: :string, aliases: '-r', banner: 'PATH'
      option :path, type: :array, banner: 'PATH[,PATH...]'
      def conflict_blocks
        repo_path = options[:repo] || Dir.pwd
        git_cli = PatchUtil::Git::Cli.new
        unless git_cli.inside_repo?(repo_path)
          raise ValidationError,
                'rewrite conflict-blocks requires a git repository'
        end

        branch = git_cli.current_branch(repo_path)
        raise ValidationError, 'rewrite conflict-blocks requires a checked out branch' if branch.empty?

        result = PatchUtil::Git::RewriteSessionManager.new.conflict_blocks(repo_path: repo_path, paths: options[:path])
        if result.blocks.empty?
          puts 'no conflict blocks found in the retained worktree'
          return
        end

        result.blocks.each do |block|
          puts "path: #{block.path}"
          puts "block id: #{block.block_id}"
          puts "line range: #{block.start_line}-#{block.end_line}"
          puts 'ours:'
          puts format_multiline(block.ours)
          unless block.ancestor.empty?
            puts 'ancestor:'
            puts format_multiline(block.ancestor)
          end
          puts 'theirs:'
          puts format_multiline(block.theirs)
          puts 'excerpt:'
          puts format_multiline(block.excerpt)
          puts '--'
        end
      end

      desc 'export-block', 'Export one retained conflict block into an editable template file'
      option :repo, type: :string, aliases: '-r', banner: 'PATH'
      option :path, type: :string, required: true, banner: 'PATH'
      option :block, type: :numeric, required: true, banner: 'N'
      option :output, type: :string, required: true, aliases: '-o', banner: 'PATH'
      def export_block
        repo_path = options[:repo] || Dir.pwd
        git_cli = PatchUtil::Git::Cli.new
        raise ValidationError, 'rewrite export-block requires a git repository' unless git_cli.inside_repo?(repo_path)

        result = PatchUtil::Git::RewriteSessionManager.new.export_conflict_block(
          repo_path: repo_path,
          path: options[:path],
          block_id: options[:block],
          output_path: options[:output]
        )

        puts "retained worktree: #{result.worktree_path}"
        puts "exported block #{result.block_id} from #{result.path} to #{result.output_path}"
      end

      desc 'apply-block-edit', 'Apply edited block template content back into the retained worktree'
      option :repo, type: :string, aliases: '-r', banner: 'PATH'
      option :path, type: :string, required: true, banner: 'PATH'
      option :block, type: :numeric, required: true, banner: 'N'
      option :input, type: :string, required: true, aliases: '-i', banner: 'PATH'
      def apply_block_edit
        repo_path = options[:repo] || Dir.pwd
        git_cli = PatchUtil::Git::Cli.new
        unless git_cli.inside_repo?(repo_path)
          raise ValidationError,
                'rewrite apply-block-edit requires a git repository'
        end

        result = PatchUtil::Git::RewriteSessionManager.new.apply_conflict_block_edit(
          repo_path: repo_path,
          path: options[:path],
          block_id: options[:block],
          input_path: options[:input]
        )

        puts "retained worktree: #{result.worktree_path}"
        puts "applied edited block #{result.block_id} from #{result.input_path} into #{result.path}"
        puts "remaining blocks in file: #{result.remaining_blocks.length}"
        if result.remaining_blocks.any?
          puts "remaining block ids: #{result.remaining_blocks.map(&:block_id).join(', ')}"
          puts 'file still has conflict markers; it is not staged yet'
        else
          puts 'file has no remaining conflict markers and is staged'
        end
      end

      desc 'export-session', 'Export multiple retained conflict blocks into one editable session file'
      option :repo, type: :string, aliases: '-r', banner: 'PATH'
      option :path, type: :array, banner: 'PATH[,PATH...]'
      option :output, type: :string, required: true, aliases: '-o', banner: 'PATH'
      def export_session
        repo_path = options[:repo] || Dir.pwd
        git_cli = PatchUtil::Git::Cli.new
        raise ValidationError, 'rewrite export-session requires a git repository' unless git_cli.inside_repo?(repo_path)

        result = PatchUtil::Git::RewriteSessionManager.new.export_conflict_block_session(
          repo_path: repo_path,
          paths: options[:path],
          output_path: options[:output]
        )

        puts "retained worktree: #{result.worktree_path}"
        puts "exported #{result.blocks.length} blocks to #{result.output_path}"
        puts "files in session: #{result.files.length}"
        print_conflict_block_file_summary(result.files)
      end

      desc 'apply-session-edit', 'Apply a multi-block edited session template back into the retained worktree'
      option :repo, type: :string, aliases: '-r', banner: 'PATH'
      option :input, type: :string, required: true, aliases: '-i', banner: 'PATH'
      def apply_session_edit
        repo_path = options[:repo] || Dir.pwd
        git_cli = PatchUtil::Git::Cli.new
        unless git_cli.inside_repo?(repo_path)
          raise ValidationError,
                'rewrite apply-session-edit requires a git repository'
        end

        result = PatchUtil::Git::RewriteSessionManager.new.apply_conflict_block_session_edit(
          repo_path: repo_path,
          input_path: options[:input]
        )

        puts "retained worktree: #{result.worktree_path}"
        puts "applied #{result.applied_blocks.length} edited blocks from #{result.input_path}"
        puts "staged paths: #{result.staged_paths.length}"
        puts "staged path list: #{result.staged_paths.join(', ')}" if result.staged_paths.any?

        remaining_files = result.remaining_blocks_by_file.select { |_path, blocks| blocks.any? }
        puts "files still containing conflict blocks: #{remaining_files.length}"
        if remaining_files.any?
          puts "remaining conflict files: #{remaining_files.keys.join(', ')}"
        else
          puts 'all edited files are free of conflict markers'
        end

        print_applied_session_file_summary(result.files)
      end

      desc 'session-summary', 'Show file-aware retained conflict block session summary'
      option :repo, type: :string, aliases: '-r', banner: 'PATH'
      option :path, type: :array, banner: 'PATH[,PATH...]'
      def session_summary
        repo_path = options[:repo] || Dir.pwd
        git_cli = PatchUtil::Git::Cli.new
        unless git_cli.inside_repo?(repo_path)
          raise ValidationError,
                'rewrite session-summary requires a git repository'
        end

        result = PatchUtil::Git::RewriteSessionManager.new.conflict_block_session_summary(
          repo_path: repo_path,
          paths: options[:path]
        )

        puts "retained worktree: #{result.worktree_path}"
        puts "files with conflict blocks: #{result.files.length}"
        puts "total conflict blocks: #{result.blocks.length}"
        if result.files.empty?
          puts 'no conflict blocks found for session export'
          return
        end

        print_conflict_block_file_summary(result.files)
      end

      desc 'resolve', 'Choose ours/theirs for retained unresolved paths and stage them'
      option :repo, type: :string, aliases: '-r', banner: 'PATH'
      option :side, type: :string, required: true, banner: 'ours|theirs'
      option :path, type: :array, banner: 'PATH[,PATH...]'
      option :all, type: :boolean, default: false, banner: 'BOOL'
      def resolve
        repo_path = options[:repo] || Dir.pwd
        git_cli = PatchUtil::Git::Cli.new
        raise ValidationError, 'rewrite resolve requires a git repository' unless git_cli.inside_repo?(repo_path)
        raise ValidationError, 'use either --path or --all, not both' if options[:all] && options[:path]

        result = PatchUtil::Git::RewriteSessionManager.new.resolve_conflicts(
          repo_path: repo_path,
          side: options[:side],
          paths: options[:path],
          all_unresolved: options[:all]
        )

        puts "retained worktree: #{result.worktree_path}"
        puts "resolved with #{result.side}: #{result.resolved_paths.join(', ')}"
        puts "remaining unresolved paths: #{result.remaining_unresolved_paths.length}"
        if result.remaining_unresolved_paths.any?
          puts "remaining unresolved path list: #{result.remaining_unresolved_paths.join(', ')}"
        else
          puts 'all retained unresolved paths are now staged'
        end
      end

      desc 'resolve-block', 'Resolve one retained conflict block within a file'
      option :repo, type: :string, aliases: '-r', banner: 'PATH'
      option :path, type: :string, required: true, banner: 'PATH'
      option :block, type: :numeric, required: true, banner: 'N'
      option :side, type: :string, required: true, banner: 'ours|theirs|ancestor'
      def resolve_block
        repo_path = options[:repo] || Dir.pwd
        git_cli = PatchUtil::Git::Cli.new
        raise ValidationError, 'rewrite resolve-block requires a git repository' unless git_cli.inside_repo?(repo_path)

        result = PatchUtil::Git::RewriteSessionManager.new.resolve_conflict_block(
          repo_path: repo_path,
          path: options[:path],
          block_id: options[:block],
          side: options[:side]
        )

        puts "retained worktree: #{result.worktree_path}"
        puts "resolved block #{result.block_id} in #{result.path} with #{result.side}"
        puts "remaining blocks in file: #{result.remaining_blocks.length}"
        if result.remaining_blocks.any?
          puts "remaining block ids: #{result.remaining_blocks.map(&:block_id).join(', ')}"
          puts 'file still has conflict markers; it is not staged yet'
        else
          puts 'file has no remaining conflict markers and is staged'
        end
      end

      no_commands do
        def format_multiline(text)
          return '  <empty>' if text.empty?

          text.lines(chomp: true).map { |line| "  #{line}" }.join("\n")
        end

        def print_conflict_block_file_summary(files)
          files.each do |path, info|
            puts "path: #{path}"
            puts "block count: #{info[:block_count]}"
            puts "block ids: #{format_id_list(info[:block_ids])}"
            puts "has ancestor blocks: #{info[:has_ancestor]}"
            puts '--'
          end
        end

        def print_applied_session_file_summary(files)
          files.each do |path, info|
            puts "path: #{path}"
            puts "applied block count: #{info[:applied_block_count]}"
            puts "applied block ids: #{format_id_list(info[:applied_block_ids])}"
            puts "remaining block count: #{info[:remaining_block_count]}"
            puts "remaining block ids: #{format_id_list(info[:remaining_block_ids])}"
            puts "staged: #{info[:staged]}"
            puts '--'
          end
        end

        def format_id_list(ids)
          return '<none>' if ids.empty?

          ids.join(', ')
        end
      end
    end
  end
end
