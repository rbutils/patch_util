# frozen_string_literal: true

require 'time'

module PatchUtil
  module Git
    class RewriteSessionManager
      Result = Data.define(:branch, :old_head, :new_head, :backup_ref, :commits)
      AbortResult = Data.define(:branch, :backup_ref, :worktree_path, :worktree_removed)
      RestoreResult = Data.define(:branch, :old_head, :restored_head, :backup_ref, :worktree_path,
                                  :worktree_removed)
      ResolveResult = Data.define(:branch, :worktree_path, :side, :resolved_paths, :remaining_unresolved_paths)
      ResolveBlockResult = Data.define(:branch, :worktree_path, :path, :block_id, :side, :remaining_blocks,
                                       :staged)
      ConflictBlocksResult = Data.define(:branch, :worktree_path, :blocks)
      ExportBlockResult = Data.define(:branch, :worktree_path, :path, :block_id, :output_path)
      ApplyBlockEditResult = Data.define(:branch, :worktree_path, :path, :block_id, :input_path, :remaining_blocks,
                                         :staged)
      ExportBlockSessionResult = Data.define(:branch, :worktree_path, :output_path, :blocks, :files)
      ApplyBlockSessionEditResult = Data.define(:branch, :worktree_path, :input_path, :applied_blocks,
                                                :remaining_blocks_by_file, :staged_paths, :files)
      SessionSummaryResult = Data.define(:branch, :worktree_path, :blocks, :files)
      Status = Data.define(:branch, :head_sha, :state, :head_matches, :worktree_exists, :worktree_clean,
                           :cherry_pick_in_progress, :current_revision, :unresolved_paths,
                           :conflict_marker_details)

      def initialize(git_cli: Cli.new, clock: -> { Time.now.utc })
        @git_cli = git_cli
        @clock = clock
      end

      def abort_rewrite(repo_path:)
        branch = @git_cli.current_branch(repo_path)
        raise PatchUtil::ValidationError, 'rewrite abort requires a checked out branch' if branch.empty?

        state_store = RewriteStateStore.new(git_dir: @git_cli.git_dir(repo_path))
        state = state_store.find_branch(branch)
        raise PatchUtil::ValidationError, "no retained rewrite state for branch #{branch}" unless state

        worktree_removed = remove_retained_worktree(repo_path, state.worktree_path)
        state_store.clear_branch(branch)

        AbortResult.new(
          branch: branch,
          backup_ref: state.backup_ref,
          worktree_path: state.worktree_path,
          worktree_removed: worktree_removed
        )
      end

      def continue_rewrite(repo_path:)
        branch, head, state_store, state = resume_state_for(repo_path)
        worktree = state.worktree_path
        pending_revisions = state.pending_revisions.dup

        begin
          if @git_cli.cherry_pick_in_progress?(worktree)
            current_revision = @git_cli.cherry_pick_head(worktree)
            pending_revisions = normalize_pending_revisions(repo_path, state, current_revision, pending_revisions)
            @git_cli.cherry_pick_continue(worktree, env: replay_commit_env(repo_path, current_revision))
            pending_revisions.shift if pending_revisions.first == current_revision
          elsif !@git_cli.worktree_clean?(worktree)
            raise PatchUtil::ValidationError,
                  'retained rewrite worktree has unresolved changes; finish the in-progress cherry-pick or clean it before continuing'
          end

          until pending_revisions.empty?
            revision = pending_revisions.first
            @git_cli.cherry_pick(worktree, revision, env: replay_commit_env(repo_path, revision))
            pending_revisions.shift
          end

          finalize_rewrite(repo_path, branch, head, state.backup_ref, worktree, state_store)
        rescue PatchUtil::Error, PatchUtil::ValidationError => e
          state_store.record_failure(
            RewriteStateStore::State.new(
              branch: state.branch,
              target_sha: state.target_sha,
              head_sha: state.head_sha,
              backup_ref: state.backup_ref,
              worktree_path: state.worktree_path,
              status: 'failed',
              message: e.message,
              created_at: @clock.call.iso8601,
              pending_revisions: pending_revisions
            )
          )
          raise PatchUtil::Error,
                continue_failure_message(state, worktree, e.message)
        end
      end

      def status(repo_path:)
        branch = @git_cli.current_branch(repo_path)
        raise PatchUtil::ValidationError, 'rewrite-status requires a checked out branch' if branch.empty?

        state_store = RewriteStateStore.new(git_dir: @git_cli.git_dir(repo_path))
        state = state_store.find_branch(branch)
        return nil unless state

        head_sha = @git_cli.head_sha(repo_path)
        worktree_exists = File.directory?(state.worktree_path)
        cherry_pick_in_progress = worktree_exists && @git_cli.cherry_pick_in_progress?(state.worktree_path)
        current_revision = cherry_pick_in_progress ? @git_cli.cherry_pick_head(state.worktree_path) : nil
        worktree_clean = worktree_exists ? @git_cli.worktree_clean?(state.worktree_path) : nil
        unresolved_paths = worktree_exists ? @git_cli.unresolved_paths(state.worktree_path) : []
        conflict_marker_details = if worktree_exists
                                    @git_cli.conflict_marker_details(state.worktree_path,
                                                                     file_paths: unresolved_paths)
                                  else
                                    []
                                  end
        if worktree_exists && conflict_marker_details.empty?
          conflict_marker_details = @git_cli.conflict_marker_details(state.worktree_path)
        end

        Status.new(
          branch: branch,
          head_sha: head_sha,
          state: state,
          head_matches: head_sha == state.head_sha,
          worktree_exists: worktree_exists,
          worktree_clean: worktree_clean,
          cherry_pick_in_progress: cherry_pick_in_progress,
          current_revision: current_revision,
          unresolved_paths: unresolved_paths,
          conflict_marker_details: conflict_marker_details
        )
      end

      def restore_rewrite(repo_path:)
        unless @git_cli.worktree_clean?(repo_path)
          raise PatchUtil::ValidationError,
                'restore-rewrite requires a clean worktree'
        end

        branch = @git_cli.current_branch(repo_path)
        raise PatchUtil::ValidationError, 'restore-rewrite requires a checked out branch' if branch.empty?

        state_store = RewriteStateStore.new(git_dir: @git_cli.git_dir(repo_path))
        state = state_store.find_branch(branch)
        raise PatchUtil::ValidationError, "no retained rewrite state for branch #{branch}" unless state

        old_head = @git_cli.head_sha(repo_path)
        restored_head = resolve_backup_ref(repo_path, state.backup_ref)

        @git_cli.reset_hard(repo_path, restored_head)
        worktree_removed = remove_retained_worktree(repo_path, state.worktree_path)
        state_store.clear_branch(branch)

        RestoreResult.new(
          branch: branch,
          old_head: old_head,
          restored_head: restored_head,
          backup_ref: state.backup_ref,
          worktree_path: state.worktree_path,
          worktree_removed: worktree_removed
        )
      end

      def resolve_conflicts(repo_path:, side:, paths: nil, all_unresolved: false)
        branch = @git_cli.current_branch(repo_path)
        raise PatchUtil::ValidationError, 'rewrite-resolve requires a checked out branch' if branch.empty?

        state_store = RewriteStateStore.new(git_dir: @git_cli.git_dir(repo_path))
        state = state_store.find_branch(branch)
        raise PatchUtil::ValidationError, "no retained rewrite state for branch #{branch}" unless state

        unless File.directory?(state.worktree_path)
          raise PatchUtil::ValidationError,
                "retained rewrite worktree is missing: #{state.worktree_path}"
        end

        unresolved_paths = @git_cli.unresolved_paths(state.worktree_path)
        if unresolved_paths.empty?
          raise PatchUtil::ValidationError,
                'no unresolved paths found in the retained worktree'
        end

        resolved_paths = if all_unresolved
                           unresolved_paths
                         else
                           normalized_paths = Array(paths).map(&:to_s).map(&:strip).reject(&:empty?).uniq
                           if normalized_paths.empty?
                             raise PatchUtil::ValidationError,
                                   'provide --path PATH[,PATH...] or --all'
                           end

                           unknown_paths = normalized_paths - unresolved_paths
                           unless unknown_paths.empty?
                             raise PatchUtil::ValidationError,
                                   "paths are not currently unresolved: #{unknown_paths.join(', ')}"
                           end

                           normalized_paths
                         end

        @git_cli.checkout_conflict_side(state.worktree_path, side, resolved_paths)
        @git_cli.add_paths(state.worktree_path, resolved_paths)
        remaining_unresolved_paths = @git_cli.unresolved_paths(state.worktree_path)

        ResolveResult.new(
          branch: branch,
          worktree_path: state.worktree_path,
          side: side,
          resolved_paths: resolved_paths,
          remaining_unresolved_paths: remaining_unresolved_paths
        )
      end

      def resolve_conflict_block(repo_path:, path:, block_id:, side:)
        branch = @git_cli.current_branch(repo_path)
        raise PatchUtil::ValidationError, 'rewrite-resolve-block requires a checked out branch' if branch.empty?

        state_store = RewriteStateStore.new(git_dir: @git_cli.git_dir(repo_path))
        state = state_store.find_branch(branch)
        raise PatchUtil::ValidationError, "no retained rewrite state for branch #{branch}" unless state

        unless File.directory?(state.worktree_path)
          raise PatchUtil::ValidationError,
                "retained rewrite worktree is missing: #{state.worktree_path}"
        end

        details = @git_cli.conflict_block_details(state.worktree_path, file_paths: [path])
        raise PatchUtil::ValidationError, "no conflict blocks found for #{path}" if details.empty?

        result = @git_cli.resolve_conflict_block(state.worktree_path, file_path: path, block_id: block_id, side: side)

        ResolveBlockResult.new(
          branch: branch,
          worktree_path: state.worktree_path,
          path: path,
          block_id: block_id,
          side: side,
          remaining_blocks: result[:remaining_blocks],
          staged: result[:staged]
        )
      end

      def conflict_blocks(repo_path:, paths: nil)
        branch = @git_cli.current_branch(repo_path)
        raise PatchUtil::ValidationError, 'rewrite-conflict-blocks requires a checked out branch' if branch.empty?

        state_store = RewriteStateStore.new(git_dir: @git_cli.git_dir(repo_path))
        state = state_store.find_branch(branch)
        raise PatchUtil::ValidationError, "no retained rewrite state for branch #{branch}" unless state

        unless File.directory?(state.worktree_path)
          raise PatchUtil::ValidationError,
                "retained rewrite worktree is missing: #{state.worktree_path}"
        end

        selected_paths = Array(paths).map(&:to_s).map(&:strip).reject(&:empty?).uniq
        selected_paths = nil if selected_paths.empty?
        blocks = @git_cli.conflict_block_details(state.worktree_path, file_paths: selected_paths)

        ConflictBlocksResult.new(
          branch: branch,
          worktree_path: state.worktree_path,
          blocks: blocks
        )
      end

      def export_conflict_block(repo_path:, path:, block_id:, output_path:)
        branch, state = retained_state_for(repo_path, command_name: 'rewrite-export-block')
        @git_cli.export_conflict_block_template(state.worktree_path, file_path: path, block_id: block_id,
                                                                     output_path: output_path)

        ExportBlockResult.new(
          branch: branch,
          worktree_path: state.worktree_path,
          path: path,
          block_id: block_id,
          output_path: File.expand_path(output_path)
        )
      end

      def apply_conflict_block_edit(repo_path:, path:, block_id:, input_path:)
        branch, state = retained_state_for(repo_path, command_name: 'rewrite-apply-block-edit')
        details = @git_cli.conflict_block_details(state.worktree_path, file_paths: [path])
        raise PatchUtil::ValidationError, "no conflict blocks found for #{path}" if details.empty?

        result = @git_cli.apply_conflict_block_edit(state.worktree_path, file_path: path, block_id: block_id,
                                                                         input_path: input_path)

        ApplyBlockEditResult.new(
          branch: branch,
          worktree_path: state.worktree_path,
          path: path,
          block_id: block_id,
          input_path: File.expand_path(input_path),
          remaining_blocks: result[:remaining_blocks],
          staged: result[:staged]
        )
      end

      def export_conflict_block_session(repo_path:, output_path:, paths: nil)
        branch, state = retained_state_for(repo_path, command_name: 'rewrite-export-session')
        selected_paths = Array(paths).map(&:to_s).map(&:strip).reject(&:empty?).uniq
        selected_paths = nil if selected_paths.empty?
        result = @git_cli.export_conflict_block_session_template(state.worktree_path, file_paths: selected_paths,
                                                                                      output_path: output_path)

        ExportBlockSessionResult.new(
          branch: branch,
          worktree_path: state.worktree_path,
          output_path: result[:output_path],
          blocks: result[:blocks],
          files: summarize_conflict_blocks_by_file(result[:blocks])
        )
      end

      def apply_conflict_block_session_edit(repo_path:, input_path:)
        branch, state = retained_state_for(repo_path, command_name: 'rewrite-apply-session-edit')
        result = @git_cli.apply_conflict_block_session_edit(state.worktree_path, input_path: input_path)

        ApplyBlockSessionEditResult.new(
          branch: branch,
          worktree_path: state.worktree_path,
          input_path: File.expand_path(input_path),
          applied_blocks: result[:applied_blocks],
          remaining_blocks_by_file: result[:remaining_blocks_by_file],
          staged_paths: result[:staged_paths],
          files: summarize_applied_blocks_by_file(
            applied_blocks: result[:applied_blocks],
            remaining_blocks_by_file: result[:remaining_blocks_by_file],
            staged_paths: result[:staged_paths]
          )
        )
      end

      def conflict_block_session_summary(repo_path:, paths: nil)
        branch, state = retained_state_for(repo_path, command_name: 'rewrite-session-summary')
        selected_paths = Array(paths).map(&:to_s).map(&:strip).reject(&:empty?).uniq
        selected_paths = nil if selected_paths.empty?
        blocks = @git_cli.conflict_block_details(state.worktree_path, file_paths: selected_paths)

        SessionSummaryResult.new(
          branch: branch,
          worktree_path: state.worktree_path,
          blocks: blocks,
          files: summarize_conflict_blocks_by_file(blocks)
        )
      end

      def next_action(status)
        return 'run restore-rewrite or abort-rewrite; retained worktree is missing' unless status.worktree_exists
        return 'run restore-rewrite before continuing; branch head changed' unless status.head_matches
        return 'resolve conflicts in retained worktree, then run continue-rewrite' if status.cherry_pick_in_progress
        if status.conflict_marker_details.any?
          return 'inspect conflict markers with rewrite-conflicts, resolve them in the retained worktree, then run continue-rewrite'
        end
        if status.unresolved_paths.any?
          return 'resolve unresolved paths in the retained worktree, then run continue-rewrite'
        end
        return 'clean the retained worktree or abort-rewrite before continuing' if status.worktree_clean == false
        return 'run continue-rewrite to replay the remaining descendant commits' if status.state.pending_revisions.any?

        'run continue-rewrite to finalize the retained rewrite'
      end

      private

      def retained_state_for(repo_path, command_name:)
        branch = @git_cli.current_branch(repo_path)
        raise PatchUtil::ValidationError, "#{command_name} requires a checked out branch" if branch.empty?

        state_store = RewriteStateStore.new(git_dir: @git_cli.git_dir(repo_path))
        state = state_store.find_branch(branch)
        raise PatchUtil::ValidationError, "no retained rewrite state for branch #{branch}" unless state

        unless File.directory?(state.worktree_path)
          raise PatchUtil::ValidationError,
                "retained rewrite worktree is missing: #{state.worktree_path}"
        end

        [branch, state]
      end

      def summarize_conflict_blocks_by_file(blocks)
        blocks.group_by(&:path).transform_values do |file_blocks|
          {
            block_ids: file_blocks.map(&:block_id).sort,
            block_count: file_blocks.length,
            has_ancestor: file_blocks.any? { |block| !block.ancestor.empty? }
          }
        end.sort.to_h
      end

      def summarize_applied_blocks_by_file(applied_blocks:, remaining_blocks_by_file:, staged_paths:)
        all_paths = (applied_blocks.map { |entry| entry[:path] } + remaining_blocks_by_file.keys).uniq.sort
        summary = {}

        all_paths.each do |path|
          file_applied_blocks = applied_blocks.select { |entry| entry[:path] == path }
                                              .sort_by { |entry| entry[:block_id] }
          remaining_blocks = remaining_blocks_by_file.fetch(path, []).sort_by(&:block_id)

          summary[path] = {
            applied_block_ids: file_applied_blocks.map { |entry| entry[:block_id] },
            applied_block_count: file_applied_blocks.length,
            remaining_block_ids: remaining_blocks.map(&:block_id),
            remaining_block_count: remaining_blocks.length,
            staged: staged_paths.include?(path)
          }
        end

        summary
      end

      def resolve_backup_ref(repo_path, backup_ref)
        @git_cli.rev_parse(repo_path, backup_ref)
      rescue PatchUtil::Error
        raise PatchUtil::ValidationError, "backup ref #{backup_ref} no longer exists"
      end

      def remove_retained_worktree(repo_path, worktree_path)
        return false unless File.directory?(worktree_path)

        @git_cli.worktree_remove(repo_path, worktree_path)
        true
      end

      def continue_failure_message(state, worktree, message)
        lines = [message, "backup ref: #{state.backup_ref}", "retained worktree: #{state.worktree_path}"]
        unresolved_paths = @git_cli.unresolved_paths(worktree)
        if unresolved_paths.any?
          lines << "unresolved paths: #{unresolved_paths.join(', ')}"
          lines << 'next step: resolve the listed paths in the retained worktree, then run rewrite-status or continue-rewrite'
        else
          lines << 'next step: run rewrite-status to inspect the retained state before continuing or aborting'
        end
        lines.join("\n")
      end

      def resume_state_for(repo_path)
        unless @git_cli.worktree_clean?(repo_path)
          raise PatchUtil::ValidationError,
                'continue-rewrite requires a clean worktree'
        end

        branch = @git_cli.current_branch(repo_path)
        raise PatchUtil::ValidationError, 'continue-rewrite requires a checked out branch' if branch.empty?

        state_store = RewriteStateStore.new(git_dir: @git_cli.git_dir(repo_path))
        state = state_store.find_branch(branch)
        raise PatchUtil::ValidationError, "no retained rewrite state for branch #{branch}" unless state

        head = @git_cli.head_sha(repo_path)
        unless head == state.head_sha
          raise PatchUtil::ValidationError,
                "branch #{branch} moved from #{state.head_sha} to #{head}; run restore-rewrite to restore from #{state.backup_ref} before continuing"
        end

        unless File.directory?(state.worktree_path)
          raise PatchUtil::ValidationError,
                "retained rewrite worktree is missing: #{state.worktree_path}; run restore-rewrite or abort-rewrite"
        end

        [branch, head, state_store, state]
      end

      def normalize_pending_revisions(repo_path, state, current_revision, pending_revisions)
        return pending_revisions if pending_revisions.first == current_revision

        [current_revision, *@git_cli.rev_list(repo_path, "#{current_revision}..#{state.head_sha}")]
      end

      def replay_commit_env(repo_path, revision)
        original_commit = @git_cli.show_commit_metadata(repo_path, revision)
        {
          'GIT_COMMITTER_NAME' => original_commit.committer_name,
          'GIT_COMMITTER_EMAIL' => original_commit.committer_email,
          'GIT_COMMITTER_DATE' => original_commit.committer_date
        }
      end

      def finalize_rewrite(repo_path, branch, old_head, backup_ref, worktree, state_store)
        new_head = @git_cli.head_sha(worktree)
        @git_cli.update_ref(repo_path, "refs/heads/#{branch}", new_head, old_head)
        @git_cli.reset_hard(repo_path, new_head)
        @git_cli.worktree_remove(repo_path, worktree)
        state_store.clear_branch(branch)

        Result.new(branch: branch, old_head: old_head, new_head: new_head, backup_ref: backup_ref, commits: [])
      end
    end
  end
end
