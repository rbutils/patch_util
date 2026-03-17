# frozen_string_literal: true

require 'fileutils'
require 'time'

module PatchUtil
  module Git
    class Rewriter
      Result = RewriteSessionManager::Result
      AbortResult = RewriteSessionManager::AbortResult
      RestoreResult = RewriteSessionManager::RestoreResult
      ResolveResult = RewriteSessionManager::ResolveResult
      ResolveBlockResult = RewriteSessionManager::ResolveBlockResult
      ConflictBlocksResult = RewriteSessionManager::ConflictBlocksResult
      ExportBlockResult = RewriteSessionManager::ExportBlockResult
      ApplyBlockEditResult = RewriteSessionManager::ApplyBlockEditResult
      ExportBlockSessionResult = RewriteSessionManager::ExportBlockSessionResult
      ApplyBlockSessionEditResult = RewriteSessionManager::ApplyBlockSessionEditResult
      SessionSummaryResult = RewriteSessionManager::SessionSummaryResult
      Status = RewriteSessionManager::Status

      def initialize(git_cli: Cli.new, applier: PatchUtil::Split::Applier.new, clock: -> { Time.now.utc },
                     session_manager: nil)
        @git_cli = git_cli
        @applier = applier
        @clock = clock
        @session_manager = session_manager || RewriteSessionManager.new(git_cli: git_cli, clock: clock)
      end

      def rewrite(source:, diff:, plan_entry:)
        repo_path = source.repo_path
        raise PatchUtil::ValidationError, 'git rewrite apply requires a git commit source' unless source.git?

        unless @git_cli.worktree_clean?(repo_path)
          raise PatchUtil::ValidationError,
                'git rewrite apply requires a clean worktree'
        end

        branch = @git_cli.current_branch(repo_path)
        raise PatchUtil::ValidationError, 'git rewrite apply requires a checked out branch' if branch.empty?

        head = @git_cli.head_sha(repo_path)
        target = source.commit_sha
        unless @git_cli.ancestor?(repo_path, target, head)
          raise PatchUtil::ValidationError, "target commit #{target} is not an ancestor of HEAD"
        end

        parent = @git_cli.rev_parse(repo_path, "#{target}^")
        descendants = @git_cli.rev_list(repo_path, "#{target}..#{head}")
        merge_descendant = descendants.find { |revision| @git_cli.merge_commit?(repo_path, revision) }
        if merge_descendant
          raise PatchUtil::ValidationError,
                "git rewrite apply does not support descendant merge commits yet: #{merge_descendant} is a merge commit in #{target}..#{head}"
        end
        original_commit = @git_cli.show_commit_metadata(repo_path, target)
        backup_ref = "refs/patch_util-backups/#{branch}/#{timestamp_token}"
        @git_cli.update_ref(repo_path, backup_ref, head)
        worktree = build_worktree_path(repo_path, branch, target)
        emitted_output_dir = File.join(worktree, '.patch_util_emitted')
        state_store = RewriteStateStore.new(git_dir: @git_cli.git_dir(repo_path))
        pending_revisions = descendants.dup

        begin
          @git_cli.worktree_add(repo_path, worktree, parent)

          emitted = @applier.apply(diff: diff, plan_entry: plan_entry,
                                   output_dir: emitted_output_dir)
          emitted.each do |item|
            @git_cli.apply_patch_text(worktree, item[:patch_text])
            FileUtils.rm_rf(emitted_output_dir)
            @git_cli.commit_all(worktree, build_commit_message(item[:name], target, original_commit),
                                env: split_commit_env(original_commit))
          end

          until pending_revisions.empty?
            revision = pending_revisions.first
            @git_cli.cherry_pick(worktree, revision)
            pending_revisions.shift
          end

          new_head = @git_cli.head_sha(worktree)
          @git_cli.update_ref(repo_path, "refs/heads/#{branch}", new_head, head)
          @git_cli.reset_hard(repo_path, new_head)
          @git_cli.worktree_remove(repo_path, worktree)
          state_store.clear_branch(branch)

          Result.new(
            branch: branch,
            old_head: head,
            new_head: new_head,
            backup_ref: backup_ref,
            commits: emitted.map { |item| item[:name] }
          )
        rescue PatchUtil::Error => e
          state_store.record_failure(
            RewriteStateStore::State.new(
              branch: branch,
              target_sha: target,
              head_sha: head,
              backup_ref: backup_ref,
              worktree_path: worktree,
              status: 'failed',
              message: e.message,
              created_at: @clock.call.iso8601,
              pending_revisions: pending_revisions
            )
          )
          raise PatchUtil::Error,
                "#{e.message}\nbackup ref: #{backup_ref}\nretained worktree: #{worktree}"
        end
      end

      def abort_rewrite(repo_path:)
        @session_manager.abort_rewrite(repo_path: repo_path)
      end

      def continue_rewrite(repo_path:)
        @session_manager.continue_rewrite(repo_path: repo_path)
      end

      def status(repo_path:)
        @session_manager.status(repo_path: repo_path)
      end

      def restore_rewrite(repo_path:)
        @session_manager.restore_rewrite(repo_path: repo_path)
      end

      def resolve_conflicts(repo_path:, side:, paths: nil, all_unresolved: false)
        @session_manager.resolve_conflicts(
          repo_path: repo_path,
          side: side,
          paths: paths,
          all_unresolved: all_unresolved
        )
      end

      def resolve_conflict_block(repo_path:, path:, block_id:, side:)
        @session_manager.resolve_conflict_block(
          repo_path: repo_path,
          path: path,
          block_id: block_id,
          side: side
        )
      end

      def conflict_blocks(repo_path:, paths: nil)
        @session_manager.conflict_blocks(repo_path: repo_path, paths: paths)
      end

      def export_conflict_block(repo_path:, path:, block_id:, output_path:)
        @session_manager.export_conflict_block(
          repo_path: repo_path,
          path: path,
          block_id: block_id,
          output_path: output_path
        )
      end

      def apply_conflict_block_edit(repo_path:, path:, block_id:, input_path:)
        @session_manager.apply_conflict_block_edit(
          repo_path: repo_path,
          path: path,
          block_id: block_id,
          input_path: input_path
        )
      end

      def export_conflict_block_session(repo_path:, output_path:, paths: nil)
        @session_manager.export_conflict_block_session(
          repo_path: repo_path,
          output_path: output_path,
          paths: paths
        )
      end

      def apply_conflict_block_session_edit(repo_path:, input_path:)
        @session_manager.apply_conflict_block_session_edit(repo_path: repo_path, input_path: input_path)
      end

      def conflict_block_session_summary(repo_path:, paths: nil)
        @session_manager.conflict_block_session_summary(repo_path: repo_path, paths: paths)
      end

      def next_action(status)
        @session_manager.next_action(status)
      end

      private

      def build_commit_message(chunk_name, target_sha, original_commit)
        sections = []
        sections << chunk_name
        sections << original_commit.body unless original_commit.body.empty?
        sections << build_split_metadata_block(target_sha, original_commit.subject)
        sections.join("\n\n")
      end

      def build_split_metadata_block(target_sha, original_subject)
        [
          "Split-from: #{target_sha}",
          "Original-subject: #{original_subject}"
        ].join("\n")
      end

      def split_commit_env(original_commit)
        {
          'GIT_AUTHOR_NAME' => original_commit.author_name,
          'GIT_AUTHOR_EMAIL' => original_commit.author_email,
          'GIT_AUTHOR_DATE' => original_commit.author_date,
          'GIT_COMMITTER_NAME' => original_commit.committer_name,
          'GIT_COMMITTER_EMAIL' => original_commit.committer_email,
          'GIT_COMMITTER_DATE' => original_commit.committer_date
        }
      end

      def timestamp_token
        @clock.call.strftime('%Y%m%d%H%M%S')
      end

      def build_worktree_path(repo_path, branch, target)
        git_dir = @git_cli.git_dir(repo_path)
        root = File.join(git_dir, 'patch_util', 'rewrite-worktrees')
        FileUtils.mkdir_p(root)
        File.join(root, "#{timestamp_token}-#{sanitize(branch)}-#{target[0, 12]}")
      end

      def sanitize(text)
        text.gsub(/[^a-zA-Z0-9._-]+/, '-')
      end
    end
  end
end
