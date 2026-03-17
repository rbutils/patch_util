# frozen_string_literal: true

RSpec.describe PatchUtil::CLI do
  def build_rewrite_state(branch: 'main', target_sha: 'targetsha', head_sha: 'headsha',
                          backup_ref: 'refs/patch_util-backups/main/fake',
                          worktree_path: '/tmp/retained', message: 'previous failure',
                          pending_revisions: ['descsha'])
    PatchUtil::Git::RewriteStateStore::State.new(
      branch: branch,
      target_sha: target_sha,
      head_sha: head_sha,
      backup_ref: backup_ref,
      worktree_path: worktree_path,
      status: 'failed',
      message: message,
      created_at: Time.now.utc.iso8601,
      pending_revisions: pending_revisions
    )
  end

  def stub_git_cli(repo_path: '/repo', branch: 'main')
    double('git_cli').tap do |git_cli|
      allow(git_cli).to receive(:inside_repo?).with(repo_path).and_return(true)
      allow(git_cli).to receive(:current_branch).with(repo_path).and_return(branch)
      allow(git_cli).to receive(:conflict_block_details).and_return([])
    end
  end

  def stub_session_manager
    double('rewrite_session_manager')
  end

  it 'aborts retained rewrite state through the top-level rewrite CLI' do
    create_git_repo_with_patch do |repo_dir|
      git_dir = run_git(repo_dir, %w[rev-parse --absolute-git-dir]).strip
      branch = run_git(repo_dir, %w[branch --show-current]).strip
      worktree = File.join(git_dir, 'patch_util', 'rewrite-worktrees', 'retained-abort')
      run_git(repo_dir, ['worktree', 'add', '--detach', worktree, 'HEAD'])

      write_retained_state(
        git_dir: git_dir,
        branch: branch,
        target_sha: 'targetsha',
        head_sha: run_git(repo_dir, %w[rev-parse HEAD]).strip,
        worktree_path: worktree,
        backup_ref: "refs/patch_util-backups/#{branch}/abort"
      )

      output = capture_stdout do
        described_class.start(['rewrite', 'abort', '--repo', repo_dir])
      end

      output.should include("removed retained worktree #{worktree}")
      output.should include("backup ref remains at refs/patch_util-backups/#{branch}/abort")
      File.directory?(worktree).should
      run_git(repo_dir, %w[worktree list]).should_not include(worktree)
      PatchUtil::Git::RewriteStateStore.new(git_dir: git_dir).find_branch(branch).should be_nil
    end
  end

  it 'restores the branch through the top-level rewrite CLI' do
    create_linear_git_repo_for_rewrite do |repo_dir, shas|
      git_dir = run_git(repo_dir, %w[rev-parse --absolute-git-dir]).strip
      branch = run_git(repo_dir, %w[branch --show-current]).strip
      worktree = File.join(git_dir, 'patch_util', 'rewrite-worktrees', 'retained-restore-cli')
      FileUtils.mkdir_p(File.dirname(worktree))
      backup_ref = "refs/patch_util-backups/#{branch}/restore-cli"

      run_git(repo_dir, ['update-ref', backup_ref, shas[:base]])
      run_git(repo_dir, ['worktree', 'add', '--detach', worktree, shas[:base]])
      write_retained_state(
        git_dir: git_dir,
        branch: branch,
        target_sha: shas[:change],
        head_sha: shas[:follow_up],
        worktree_path: worktree,
        backup_ref: backup_ref
      )

      output = capture_stdout do
        described_class.start(['rewrite', 'restore', '--repo', repo_dir])
      end

      output.should include("restored #{branch}: #{shas[:follow_up]} -> #{shas[:base]}")
      output.should include("removed retained worktree #{worktree}")
      output.should include("backup ref remains at #{backup_ref}")
      run_git(repo_dir, %w[rev-parse HEAD]).strip.should
      shas[:base]
      File.directory?(worktree).should
      PatchUtil::Git::RewriteStateStore.new(git_dir: git_dir).find_branch(branch).should be_nil
    end
  end

  it 'continues retained rewrite state through the top-level rewrite CLI' do
    git_cli = stub_git_cli
    manager = stub_session_manager
    result = PatchUtil::Git::RewriteSessionManager::Result.new(
      branch: 'main',
      old_head: 'oldsha',
      new_head: 'newsha',
      backup_ref: 'refs/patch_util-backups/main/fake',
      commits: []
    )

    allow(PatchUtil::Git::Cli).to receive(:new).and_return(git_cli)
    allow(PatchUtil::Git::RewriteSessionManager).to receive(:new).and_return(manager)
    allow(manager).to receive(:continue_rewrite).with(repo_path: '/repo').and_return(result)

    output = capture_stdout do
      described_class.start(['rewrite', 'continue', '--repo', '/repo'])
    end

    output.should include('rewrote main: oldsha -> newsha')
    output.should include('backup ref: refs/patch_util-backups/main/fake')
    output.should include('resumed retained rewrite state')
  end

  it 'reports when no retained rewrite state exists for rewrite status' do
    git_cli = stub_git_cli
    manager = stub_session_manager

    allow(PatchUtil::Git::Cli).to receive(:new).and_return(git_cli)
    allow(PatchUtil::Git::RewriteSessionManager).to receive(:new).and_return(manager)
    allow(manager).to receive(:status).with(repo_path: '/repo').and_return(nil)

    output = capture_stdout do
      described_class.start(['rewrite', 'status', '--repo', '/repo'])
    end

    output.should include('no retained rewrite state for branch main')
  end

  it 'prints retained rewrite status details through the top-level rewrite CLI' do
    git_cli = stub_git_cli
    manager = stub_session_manager
    state = build_rewrite_state(worktree_path: '/tmp/retained-status', pending_revisions: %w[descsha later])
    status = PatchUtil::Git::RewriteSessionManager::Status.new(
      branch: 'main',
      head_sha: 'headsha',
      state: state,
      head_matches: true,
      worktree_exists: true,
      worktree_clean: false,
      cherry_pick_in_progress: true,
      current_revision: 'descsha',
      unresolved_paths: ['example.rb', 'lib/extra.rb'],
      conflict_marker_details: [
        PatchUtil::Git::Cli::ConflictMarkerDetail.new(
          path: 'example.rb',
          marker_count: 1,
          first_marker_line: 10,
          excerpt: "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> topic"
        )
      ]
    )

    allow(PatchUtil::Git::Cli).to receive(:new).and_return(git_cli)
    allow(PatchUtil::Git::RewriteSessionManager).to receive(:new).and_return(manager)
    allow(manager).to receive(:status).with(repo_path: '/repo').and_return(status)
    allow(manager).to receive(:next_action).with(status).and_return('inspect conflict markers with rewrite-conflicts, resolve them in the retained worktree, then run continue-rewrite')

    output = capture_stdout do
      described_class.start(['rewrite', 'status', '--repo', '/repo'])
    end

    output.should include('branch: main')
    output.should include('target commit: targetsha')
    output.should include('recorded head: headsha')
    output.should include('current head: headsha')
    output.should include('backup ref: refs/patch_util-backups/main/fake')
    output.should include('retained worktree: /tmp/retained-status')
    output.should include('last error: previous failure')
    output.should include('worktree exists: true')
    output.should include('worktree clean: false')
    output.should include('unresolved paths: 2')
    output.should include('unresolved path list: example.rb, lib/extra.rb')
    output.should include('conflict marker files: 1')
    output.should include('conflict marker file list: example.rb')
    output.should include('pending revisions: 2')
    output.should include('pending revision list: descsha, later')
    output.should include('current revision: descsha')
    output.should include('branch head matches recorded state: true')
    output.should include('next action: inspect conflict markers with rewrite-conflicts, resolve them in the retained worktree, then run continue-rewrite')
  end

  it 'prints retained conflict excerpts through the top-level rewrite CLI' do
    git_cli = stub_git_cli
    state = build_rewrite_state(worktree_path: '/tmp/retained-conflicts')
    status = PatchUtil::Git::Rewriter::Status.new(
      branch: 'main',
      head_sha: 'headsha',
      state: state,
      head_matches: true,
      worktree_exists: true,
      worktree_clean: true,
      cherry_pick_in_progress: false,
      current_revision: nil,
      unresolved_paths: ['example.rb'],
      conflict_marker_details: [
        PatchUtil::Git::Cli::ConflictMarkerDetail.new(
          path: 'example.rb',
          marker_count: 1,
          first_marker_line: 5,
          excerpt: "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> topic"
        )
      ]
    )
    block = PatchUtil::Git::Cli::ConflictBlockDetail.new(
      path: 'example.rb',
      block_id: 1,
      start_line: 5,
      end_line: 9,
      ours: 'ours',
      ancestor: '',
      theirs: 'theirs',
      excerpt: "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> topic"
    )
    manager = stub_session_manager

    allow(git_cli).to receive(:conflict_block_details).with('/tmp/retained-conflicts',
                                                            file_paths: ['example.rb']).and_return([block])
    allow(PatchUtil::Git::Cli).to receive(:new).and_return(git_cli)
    allow(PatchUtil::Git::RewriteSessionManager).to receive(:new).and_return(manager)
    allow(manager).to receive(:status).with(repo_path: '/repo').and_return(status)

    output = capture_stdout do
      described_class.start(['rewrite', 'conflicts', '--repo', '/repo'])
    end

    output.should include('path: example.rb')
    output.should include('marker count: 1')
    output.should include('first marker line: 5')
    output.should include('block ids: 1')
    output.should include('<<<<<<< HEAD')
  end

  it 'prints retained conflict blocks through the top-level rewrite CLI' do
    git_cli = stub_git_cli
    manager = stub_session_manager
    block = PatchUtil::Git::Cli::ConflictBlockDetail.new(
      path: 'example.rb',
      block_id: 1,
      start_line: 5,
      end_line: 11,
      ours: "ours one\nours two",
      ancestor: 'ancestor',
      theirs: 'theirs',
      excerpt: "<<<<<<< HEAD\nours\n||||||| base\nancestor\n=======\ntheirs\n>>>>>>> topic"
    )
    result = PatchUtil::Git::RewriteSessionManager::ConflictBlocksResult.new(
      branch: 'main',
      worktree_path: '/tmp/retained-blocks',
      blocks: [block]
    )

    allow(PatchUtil::Git::Cli).to receive(:new).and_return(git_cli)
    allow(PatchUtil::Git::RewriteSessionManager).to receive(:new).and_return(manager)
    allow(manager).to receive(:conflict_blocks).with(repo_path: '/repo', paths: ['example.rb']).and_return(result)

    output = capture_stdout do
      described_class.start(['rewrite', 'conflict-blocks', '--repo', '/repo', '--path', 'example.rb'])
    end

    output.should include('path: example.rb')
    output.should include('block id: 1')
    output.should include('line range: 5-11')
    output.should include('ours:')
    output.should include('  ours one')
    output.should include('ancestor:')
    output.should include('  ancestor')
    output.should include('theirs:')
    output.should include('  theirs')
    output.should include('excerpt:')
  end

  it 'exports and reapplies a retained conflict block through the top-level rewrite CLI' do
    git_cli = stub_git_cli
    manager = stub_session_manager
    export_result = PatchUtil::Git::RewriteSessionManager::ExportBlockResult.new(
      branch: 'main',
      worktree_path: '/tmp/retained-block-edit',
      path: 'example.rb',
      block_id: 1,
      output_path: '/tmp/block.txt'
    )
    apply_result = PatchUtil::Git::RewriteSessionManager::ApplyBlockEditResult.new(
      branch: 'main',
      worktree_path: '/tmp/retained-block-edit',
      path: 'example.rb',
      block_id: 1,
      input_path: '/tmp/block.txt',
      remaining_blocks: [],
      staged: true
    )

    allow(PatchUtil::Git::Cli).to receive(:new).and_return(git_cli)
    allow(PatchUtil::Git::RewriteSessionManager).to receive(:new).and_return(manager)
    allow(manager).to receive(:export_conflict_block).with(
      repo_path: '/repo',
      path: 'example.rb',
      block_id: 1,
      output_path: '/tmp/block.txt'
    ).and_return(export_result)
    allow(manager).to receive(:apply_conflict_block_edit).with(
      repo_path: '/repo',
      path: 'example.rb',
      block_id: 1,
      input_path: '/tmp/block.txt'
    ).and_return(apply_result)

    export_output = capture_stdout do
      described_class.start([
                              'rewrite', 'export-block', '--repo', '/repo',
                              '--path', 'example.rb', '--block', '1', '--output', '/tmp/block.txt'
                            ])
    end
    apply_output = capture_stdout do
      described_class.start([
                              'rewrite', 'apply-block-edit', '--repo', '/repo',
                              '--path', 'example.rb', '--block', '1', '--input', '/tmp/block.txt'
                            ])
    end

    export_output.should include('retained worktree: /tmp/retained-block-edit')
    export_output.should include('exported block 1 from example.rb to /tmp/block.txt')
    apply_output.should include('applied edited block 1 from /tmp/block.txt into example.rb')
    apply_output.should include('remaining blocks in file: 0')
    apply_output.should include('file has no remaining conflict markers and is staged')
  end

  it 'exports, summarizes, and reapplies a retained conflict session through the top-level rewrite CLI' do
    git_cli = stub_git_cli
    manager = stub_session_manager
    block = PatchUtil::Git::Cli::ConflictBlockDetail.new(
      path: 'example.rb',
      block_id: 1,
      start_line: 5,
      end_line: 9,
      ours: 'ours',
      ancestor: '',
      theirs: 'theirs',
      excerpt: "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> topic"
    )
    export_result = PatchUtil::Git::RewriteSessionManager::ExportBlockSessionResult.new(
      branch: 'main',
      worktree_path: '/tmp/retained-session',
      output_path: '/tmp/session.txt',
      blocks: [block],
      files: {
        'example.rb' => { block_count: 1, block_ids: [1], has_ancestor: false }
      }
    )
    summary_result = PatchUtil::Git::RewriteSessionManager::SessionSummaryResult.new(
      branch: 'main',
      worktree_path: '/tmp/retained-session',
      blocks: [block],
      files: {
        'example.rb' => { block_count: 1, block_ids: [1], has_ancestor: false }
      }
    )
    apply_result = PatchUtil::Git::RewriteSessionManager::ApplyBlockSessionEditResult.new(
      branch: 'main',
      worktree_path: '/tmp/retained-session',
      input_path: '/tmp/session.txt',
      applied_blocks: [
        { path: 'example.rb', block_id: 1, replacement: 'custom text', remaining_blocks: [], staged: true }
      ],
      remaining_blocks_by_file: { 'example.rb' => [] },
      staged_paths: ['example.rb'],
      files: {
        'example.rb' => {
          applied_block_count: 1,
          applied_block_ids: [1],
          remaining_block_count: 0,
          remaining_block_ids: [],
          staged: true
        }
      }
    )

    allow(PatchUtil::Git::Cli).to receive(:new).and_return(git_cli)
    allow(PatchUtil::Git::RewriteSessionManager).to receive(:new).and_return(manager)
    allow(manager).to receive(:export_conflict_block_session).with(
      repo_path: '/repo',
      paths: ['example.rb'],
      output_path: '/tmp/session.txt'
    ).and_return(export_result)
    allow(manager).to receive(:conflict_block_session_summary).with(
      repo_path: '/repo',
      paths: ['example.rb']
    ).and_return(summary_result)
    allow(manager).to receive(:apply_conflict_block_session_edit).with(
      repo_path: '/repo',
      input_path: '/tmp/session.txt'
    ).and_return(apply_result)

    export_output = capture_stdout do
      described_class.start([
                              'rewrite', 'export-session', '--repo', '/repo',
                              '--path', 'example.rb', '--output', '/tmp/session.txt'
                            ])
    end
    summary_output = capture_stdout do
      described_class.start(['rewrite', 'session-summary', '--repo', '/repo', '--path', 'example.rb'])
    end
    apply_output = capture_stdout do
      described_class.start(['rewrite', 'apply-session-edit', '--repo', '/repo', '--input', '/tmp/session.txt'])
    end

    export_output.should include('retained worktree: /tmp/retained-session')
    export_output.should include('exported 1 blocks to /tmp/session.txt')
    export_output.should include('files in session: 1')
    export_output.should include('path: example.rb')
    export_output.should include('block count: 1')
    export_output.should include('block ids: 1')
    export_output.should include('has ancestor blocks: false')

    summary_output.should include('retained worktree: /tmp/retained-session')
    summary_output.should include('files with conflict blocks: 1')
    summary_output.should include('total conflict blocks: 1')
    summary_output.should include('path: example.rb')

    apply_output.should include('retained worktree: /tmp/retained-session')
    apply_output.should include('applied 1 edited blocks from /tmp/session.txt')
    apply_output.should include('staged paths: 1')
    apply_output.should include('staged path list: example.rb')
    apply_output.should include('files still containing conflict blocks: 0')
    apply_output.should include('all edited files are free of conflict markers')
    apply_output.should include('path: example.rb')
    apply_output.should include('applied block count: 1')
    apply_output.should include('applied block ids: 1')
    apply_output.should include('remaining block count: 0')
    apply_output.should include('remaining block ids: <none>')
    apply_output.should include('staged: true')
  end

  it 'resolves retained paths and blocks through the top-level rewrite CLI' do
    git_cli = stub_git_cli
    manager = stub_session_manager
    resolve_result = PatchUtil::Git::RewriteSessionManager::ResolveResult.new(
      branch: 'main',
      worktree_path: '/tmp/retained-resolve',
      side: 'ours',
      resolved_paths: ['example.rb'],
      remaining_unresolved_paths: ['lib/extra.rb']
    )
    resolve_block_result = PatchUtil::Git::RewriteSessionManager::ResolveBlockResult.new(
      branch: 'main',
      worktree_path: '/tmp/retained-resolve',
      path: 'example.rb',
      block_id: 1,
      side: 'theirs',
      remaining_blocks: [],
      staged: true
    )

    allow(PatchUtil::Git::Cli).to receive(:new).and_return(git_cli)
    allow(PatchUtil::Git::RewriteSessionManager).to receive(:new).and_return(manager)
    allow(manager).to receive(:resolve_conflicts).with(
      repo_path: '/repo',
      side: 'ours',
      paths: ['example.rb'],
      all_unresolved: false
    ).and_return(resolve_result)
    allow(manager).to receive(:resolve_conflict_block).with(
      repo_path: '/repo',
      path: 'example.rb',
      block_id: 1,
      side: 'theirs'
    ).and_return(resolve_block_result)

    resolve_output = capture_stdout do
      described_class.start(['rewrite', 'resolve', '--repo', '/repo', '--side', 'ours', '--path', 'example.rb'])
    end
    resolve_block_output = capture_stdout do
      described_class.start([
                              'rewrite', 'resolve-block', '--repo', '/repo',
                              '--path', 'example.rb', '--block', '1', '--side', 'theirs'
                            ])
    end

    resolve_output.should include('retained worktree: /tmp/retained-resolve')
    resolve_output.should include('resolved with ours: example.rb')
    resolve_output.should include('remaining unresolved paths: 1')
    resolve_output.should include('remaining unresolved path list: lib/extra.rb')

    resolve_block_output.should include('retained worktree: /tmp/retained-resolve')
    resolve_block_output.should include('resolved block 1 in example.rb with theirs')
    resolve_block_output.should include('remaining blocks in file: 0')
    resolve_block_output.should include('file has no remaining conflict markers and is staged')
  end
end
