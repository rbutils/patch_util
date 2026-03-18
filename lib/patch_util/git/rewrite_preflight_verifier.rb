# frozen_string_literal: true

require 'fileutils'

module PatchUtil
  module Git
    class RewritePreflightVerifier
      def initialize(git_cli: Cli.new, applier: PatchUtil::Split::Applier.new, clock: -> { Time.now.utc })
        @git_cli = git_cli
        @applier = applier
        @clock = clock
      end

      def verify(source:, parent:, diff:, plan_entry:, branch:)
        repo_path = source.repo_path
        worktree = build_worktree_path(repo_path, branch, source.commit_sha)
        output_dir = File.join(worktree, '.patch_util_emitted')
        nil
        worktree_added = false

        begin
          @git_cli.worktree_add(repo_path, worktree, parent)
          worktree_added = true
          emitted = @applier.apply(diff: diff, plan_entry: plan_entry, output_dir: output_dir)
          emitted.each do |item|
            @git_cli.check_patch_text(worktree, item[:patch_text])
            @git_cli.apply_patch_text(worktree, item[:patch_text])
          rescue PatchUtil::Error => e
            raise PatchUtil::ValidationError, "rewrite preflight failed for chunk #{item[:name]}: #{e.message}"
          end

          emitted.map do |item|
            { name: item[:name], patch_text: item[:patch_text] }
          end
        ensure
          @git_cli.worktree_remove(repo_path, worktree) if worktree_added
        end
      end

      private

      def timestamp_token
        @clock.call.strftime('%Y%m%d%H%M%S')
      end

      def build_worktree_path(repo_path, branch, target)
        git_dir = @git_cli.git_dir(repo_path)
        root = File.join(git_dir, 'patch_util', 'rewrite-preflight-worktrees')
        FileUtils.mkdir_p(root)
        File.join(root, "#{timestamp_token}-#{sanitize(branch)}-#{target[0, 12]}")
      end

      def sanitize(text)
        text.gsub(/[^a-zA-Z0-9._-]+/, '-')
      end
    end
  end
end
