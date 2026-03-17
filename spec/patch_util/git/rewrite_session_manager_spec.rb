# frozen_string_literal: true

RSpec.describe PatchUtil::Git::RewriteSessionManager do
  class AbortFakeGitCli
    attr_reader :removed_worktrees

    def initialize(git_dir:, branch: 'main')
      @git_dir = git_dir
      @branch = branch
      @removed_worktrees = []
    end

    def current_branch(_path) = @branch
    def git_dir(_path) = @git_dir

    def worktree_remove(_repo_path, worktree_path)
      @removed_worktrees << worktree_path
      FileUtils.rm_rf(worktree_path)
    end
  end

  it 'removes retained worktree through git and clears stored state on abort' do
    Dir.mktmpdir do |dir|
      git_dir = File.join(dir, '.git')
      FileUtils.mkdir_p(git_dir)
      worktree = File.join(git_dir, 'patch_util', 'rewrite-worktrees', 'retained-unit')
      FileUtils.mkdir_p(worktree)
      backup_ref = 'refs/patch_util-backups/main/unit-abort'

      write_retained_state(
        git_dir: git_dir,
        branch: 'main',
        target_sha: 'targetsha',
        head_sha: 'headsha',
        worktree_path: worktree,
        backup_ref: backup_ref
      )

      git_cli = AbortFakeGitCli.new(git_dir: git_dir)
      result = described_class.new(git_cli: git_cli).abort_rewrite(repo_path: dir)

      result.branch.should
      result.backup_ref.should
      result.worktree_path.should
      result.worktree_removed.should
      git_cli.removed_worktrees.should
      [worktree]
      File.directory?(worktree).should
      PatchUtil::Git::RewriteStateStore.new(git_dir: git_dir).find_branch('main').should be_nil
    end
  end
end
