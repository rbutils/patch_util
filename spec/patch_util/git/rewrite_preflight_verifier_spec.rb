# frozen_string_literal: true

RSpec.describe PatchUtil::Git::RewritePreflightVerifier do
  let(:planner) { PatchUtil::Split::Planner.new }

  class InvalidPreflightApplier
    def apply(diff:, plan_entry:, output_dir:)
      diff.should
      plan_entry.should
      FileUtils.mkdir_p(output_dir)
      [{ name: 'bad chunk', path: File.join(output_dir, '0001-bad-chunk.patch'), patch_text: "not a patch\n" }]
    end
  end

  it 'verifies a valid rewrite chunk series in a disposable worktree and cleans it up' do
    create_linear_git_repo_with_new_file_rewrite do |repo_dir, shas|
      source = PatchUtil::Source.from_git_commit(repo_path: repo_dir, revision: shas[:change])
      diff = PatchUtil::Parser.new.parse(source)
      plan_entry = planner.build(
        source: source,
        diff: diff,
        chunk_requests: [
          PatchUtil::Split::ChunkRequest.new(name: 'modify existing', selector_text: 'a', leftovers: false),
          PatchUtil::Split::ChunkRequest.new(name: 'add file', selector_text: 'b', leftovers: false)
        ]
      )
      branch = run_git(repo_dir, %w[branch --show-current]).strip
      git_dir = run_git(repo_dir, %w[rev-parse --absolute-git-dir]).strip

      emitted = described_class.new.verify(
        source: source,
        parent: source.parent_shas.first,
        diff: diff,
        plan_entry: plan_entry,
        branch: branch
      )

      emitted.map { |item| item[:name] }.should
      run_git(repo_dir, %w[rev-parse HEAD]).strip.should
      shas[:follow_up]
      run_git(repo_dir, %w[worktree list]).should_not include('rewrite-preflight-worktrees')
      Dir.glob(File.join(git_dir, 'patch_util', 'rewrite-preflight-worktrees', '*')).should == []
    end
  end

  it 'reports the failing chunk and removes the disposable worktree when preflight apply fails' do
    create_linear_git_repo_for_rewrite do |repo_dir, shas|
      source = PatchUtil::Source.from_git_commit(repo_path: repo_dir, revision: shas[:change])
      diff = PatchUtil::Parser.new.parse(source)
      plan_entry = planner.build(
        source: source,
        diff: diff,
        chunk_requests: [
          PatchUtil::Split::ChunkRequest.new(name: 'remove old', selector_text: 'a1', leftovers: false),
          PatchUtil::Split::ChunkRequest.new(name: 'add new', selector_text: 'a2', leftovers: false)
        ]
      )
      branch = run_git(repo_dir, %w[branch --show-current]).strip
      git_dir = run_git(repo_dir, %w[rev-parse --absolute-git-dir]).strip

      proc do
        described_class.new(applier: InvalidPreflightApplier.new).verify(
          source: source,
          parent: source.parent_shas.first,
          diff: diff,
          plan_entry: plan_entry,
          branch: branch
        )
      end.should raise_error(PatchUtil::ValidationError,
                             /rewrite preflight failed for chunk bad chunk: git apply --check failed:/)

      run_git(repo_dir, %w[rev-parse HEAD]).strip.should
      shas[:follow_up]
      run_git(repo_dir, %w[worktree list]).should_not include('rewrite-preflight-worktrees')
      Dir.glob(File.join(git_dir, 'patch_util', 'rewrite-preflight-worktrees', '*')).should == []
    end
  end
end
