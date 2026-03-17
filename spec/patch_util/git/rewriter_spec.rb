# frozen_string_literal: true

RSpec.describe PatchUtil::Git::Rewriter do
  FakeSource = Struct.new(:repo_path, :commit_sha, :kind, keyword_init: true) do
    def git?
      kind == 'git_commit'
    end
  end

  class FakeGitCli
    attr_reader :updated_refs, :removed_worktrees, :continued_cherry_picks, :cherry_picks,
                :checked_out_sides, :added_paths, :resolved_blocks, :exported_blocks, :applied_block_edits,
                :exported_sessions, :applied_session_edits, :hard_resets, :commit_calls

    def initialize(git_dir:, fail_on_cherry_pick: false, rev_parse_map: {}, missing_revisions: [])
      @git_dir = git_dir
      @fail_on_cherry_pick = fail_on_cherry_pick
      @rev_parse_map = rev_parse_map
      @missing_revisions = missing_revisions
      @updated_refs = []
      @removed_worktrees = []
      @continued_cherry_picks = []
      @cherry_picks = []
      @cherry_pick_in_progress = false
      @cherry_pick_head = nil
      @head_by_path = {}
      @unresolved_paths = []
      @conflict_marker_details = []
      @checked_out_sides = []
      @added_paths = []
      @resolved_blocks = []
      @exported_blocks = []
      @applied_block_edits = []
      @exported_sessions = []
      @applied_session_edits = []
      @hard_resets = []
      @commit_calls = []
    end

    def worktree_clean?(_path) = true
    def current_branch(_path) = 'main'
    def head_sha(path) = @head_by_path.fetch(path, 'headsha')
    def ancestor?(_path, _ancestor, _descendant) = true

    def rev_parse(_path, revision)
      raise PatchUtil::Error, "git rev-parse failed for #{revision}" if @missing_revisions.include?(revision)

      @rev_parse_map.fetch(revision, 'parentsha')
    end

    def rev_list(_path, _range) = ['descsha']
    def show_subject(_path, _revision) = 'change'

    def show_commit_metadata(_path, _revision)
      PatchUtil::Git::Cli::CommitMetadata.new(
        subject: 'change',
        body: "Co-authored-by: Pair Person <pair@example.com>\nTested-by: Test Runner <test@example.com>",
        author_name: 'Original Author',
        author_email: 'author@example.com',
        author_date: '2026-03-17T05:00:00+00:00',
        committer_name: 'Original Committer',
        committer_email: 'committer@example.com',
        committer_date: '2026-03-17T06:00:00+00:00'
      )
    end

    def git_dir(_path) = @git_dir
    def merge_commit?(_path, _revision) = false

    def worktree_add(_path, worktree_path, _revision)
      FileUtils.mkdir_p(worktree_path)
      @head_by_path[worktree_path] = 'splithead'
    end

    def apply_patch_text(_path, _patch_text)
      true
    end

    def commit_all(_path, _message, env: {})
      @commit_calls << { message: _message, env: env }
      env['GIT_AUTHOR_NAME'].should
      env['GIT_AUTHOR_EMAIL'].should
      env['GIT_AUTHOR_DATE'].should
      env['GIT_COMMITTER_NAME'].should
      env['GIT_COMMITTER_EMAIL'].should
      env['GIT_COMMITTER_DATE'].should
      true
    end

    def cherry_pick(_path, _revision, env: {})
      env.should
      @cherry_picks << _revision
      if @fail_on_cherry_pick
        @cherry_pick_in_progress = true
        @cherry_pick_head = _revision
        raise PatchUtil::Error, "git cherry-pick failed for #{_revision}: boom"
      end

      @head_by_path[_path] = "picked-#{_revision}"
      true
    end

    def cherry_pick_continue(path, env: {})
      env.should
      @continued_cherry_picks << @cherry_pick_head
      @cherry_pick_in_progress = false
      @head_by_path[path] = "continued-#{@cherry_pick_head}"
      @cherry_pick_head = nil
      true
    end

    def cherry_pick_in_progress?(_path)
      @cherry_pick_in_progress
    end

    def cherry_pick_head(_path)
      @cherry_pick_head
    end

    def unresolved_paths(_path)
      @unresolved_paths
    end

    def conflict_marker_details(_path, file_paths: nil)
      @conflict_marker_details
    end

    def conflict_block_details(_path, file_paths: nil)
      @conflict_marker_details.map.with_index(1) do |detail, index|
        next unless file_paths.nil? || file_paths.include?(detail.path)

        PatchUtil::Git::Cli::ConflictBlockDetail.new(
          path: detail.path,
          block_id: index,
          start_line: detail.first_marker_line,
          end_line: detail.first_marker_line + 4,
          ours: 'ours',
          theirs: 'theirs',
          ancestor: '',
          excerpt: detail.excerpt
        )
      end.compact
    end

    def checkout_conflict_side(_path, side, file_paths)
      @checked_out_sides << [side, file_paths]
      @unresolved_paths -= file_paths
      true
    end

    def add_paths(_path, file_paths)
      @added_paths << file_paths
      true
    end

    def resolve_conflict_block(_path, file_path:, block_id:, side:)
      @resolved_blocks << [file_path, block_id, side]
      {
        remaining_blocks: [],
        staged: true
      }
    end

    def export_conflict_block_template(_path, file_path:, block_id:, output_path:)
      @exported_blocks << [file_path, block_id, File.expand_path(output_path)]
      File.write(output_path, <<~TEMPLATE)
        # patch_util retained conflict block edit template
        ### BEGIN EDIT ###
        custom text
        ### END EDIT ###
      TEMPLATE
      File.expand_path(output_path)
    end

    def apply_conflict_block_edit(_path, file_path:, block_id:, input_path:)
      @applied_block_edits << [file_path, block_id, File.expand_path(input_path)]
      {
        remaining_blocks: [],
        staged: true
      }
    end

    def export_conflict_block_session_template(_path, output_path:, file_paths: nil)
      @exported_sessions << [file_paths, File.expand_path(output_path)]
      File.write(output_path, <<~TEMPLATE)
        # patch_util retained conflict block edit session template
        # format: patch_util-conflict-session-v1
        # block count: 2
        ### BLOCK START ###
        # path: example.rb
        # block id: 1
        ### BEGIN EDIT ###
        custom one
        ### END EDIT ###
        ### BLOCK END ###
        ### BLOCK START ###
        # path: example.rb
        # block id: 2
        ### BEGIN EDIT ###
        custom two
        ### END EDIT ###
        ### BLOCK END ###
      TEMPLATE
      {
        output_path: File.expand_path(output_path),
        blocks: conflict_block_details(_path, file_paths: file_paths)
      }
    end

    def apply_conflict_block_session_edit(_path, input_path:)
      @applied_session_edits << File.expand_path(input_path)
      {
        applied_blocks: [
          { path: 'example.rb', block_id: 1, replacement: 'custom one', remaining_blocks: [], staged: true },
          { path: 'example.rb', block_id: 2, replacement: 'custom two', remaining_blocks: [], staged: true }
        ],
        remaining_blocks_by_file: { 'example.rb' => [] },
        staged_paths: ['example.rb']
      }
    end

    def update_ref(_path, ref, new_oid, old_oid = nil)
      @updated_refs << [ref, new_oid, old_oid]
    end

    def reset_hard(path, revision)
      @hard_resets << [path, revision]
      @head_by_path[path] = revision
      true
    end

    def worktree_remove(_path, worktree_path)
      @removed_worktrees << worktree_path
      FileUtils.rm_rf(worktree_path)
    end
  end

  class FakeApplier
    def apply(diff:, plan_entry:, output_dir:)
      diff.should
      plan_entry.should
      FileUtils.mkdir_p(output_dir)
      [{ name: 'chunk one', path: File.join(output_dir, 'chunk.patch'), patch_text: "--- a/x\n+++ b/x\n" }]
    end
  end

  it 'preserves recovery information when rewrite replay fails' do
    Dir.mktmpdir do |dir|
      git_dir = File.join(dir, '.git')
      FileUtils.mkdir_p(git_dir)
      git_cli = FakeGitCli.new(git_dir: git_dir, fail_on_cherry_pick: true)
      rewriter = described_class.new(git_cli: git_cli, applier: FakeApplier.new)
      source = FakeSource.new(repo_path: dir, commit_sha: 'targetsha', kind: 'git_commit')

      error = nil
      begin
        rewriter.rewrite(source: source, diff: :diff, plan_entry: :plan)
      rescue PatchUtil::Error => e
        error = e
      end

      error.should_not be_nil
      error.message.should include('backup ref: refs/patch_util-backups/main/')
      error.message.should include('retained worktree:')
      git_cli.updated_refs.length.should
      git_cli.updated_refs.first.first.should include('refs/patch_util-backups/main/')
      git_cli.removed_worktrees.should

      retained = error.message.lines.find { |line| line.start_with?('retained worktree: ') }
      File.directory?(retained.split(': ', 2).last.strip).should
      store = PatchUtil::Git::RewriteStateStore.new(git_dir: git_dir)
      state = store.find_branch('main')
      state.should_not be_nil
      state.backup_ref.should include('refs/patch_util-backups/main/')
      state.worktree_path.should
      retained.split(': ', 2).last.strip
      state.pending_revisions.should == ['descsha']
    end
  end

  it 'preserves original author identity and message trailers on split commits' do
    Dir.mktmpdir do |dir|
      git_dir = File.join(dir, '.git')
      FileUtils.mkdir_p(git_dir)
      git_cli = FakeGitCli.new(git_dir: git_dir)
      rewriter = described_class.new(git_cli: git_cli, applier: FakeApplier.new)
      source = FakeSource.new(repo_path: dir, commit_sha: 'targetsha', kind: 'git_commit')

      rewriter.rewrite(source: source, diff: :diff, plan_entry: :plan)

      git_cli.commit_calls.length.should
      message = git_cli.commit_calls.first[:message]
      message.should include('chunk one')
      message.should include('Co-authored-by: Pair Person <pair@example.com>')
      message.should include('Tested-by: Test Runner <test@example.com>')
      message.should include('Split-from: targetsha')
      message.should include('Original-subject: change')
    end
  end

  it 'rejects rewrite when descendant replay would cross a merge commit' do
    Dir.mktmpdir do |dir|
      git_dir = File.join(dir, '.git')
      FileUtils.mkdir_p(git_dir)
      git_cli = FakeGitCli.new(git_dir: git_dir)
      allow(git_cli).to receive(:rev_list).with(dir, 'targetsha..headsha').and_return(%w[descsha mergesha later])
      allow(git_cli).to receive(:merge_commit?).with(dir, 'descsha').and_return(false)
      allow(git_cli).to receive(:merge_commit?).with(dir, 'mergesha').and_return(true)
      source = FakeSource.new(repo_path: dir, commit_sha: 'targetsha', kind: 'git_commit')

      proc do
        described_class.new(git_cli: git_cli, applier: FakeApplier.new).rewrite(source: source, diff: :diff,
                                                                                plan_entry: :plan)
      end.should raise_error(PatchUtil::ValidationError, /does not support descendant merge commits yet: mergesha/)

      git_cli.updated_refs.should
      git_cli.removed_worktrees.should == []
    end
  end

  it 'continues a retained failed rewrite and clears stored state on success' do
    Dir.mktmpdir do |dir|
      git_dir = File.join(dir, '.git')
      FileUtils.mkdir_p(git_dir)
      git_cli = FakeGitCli.new(git_dir: git_dir)
      worktree = File.join(git_dir, 'patch_util', 'rewrite-worktrees', 'retained')
      FileUtils.mkdir_p(worktree)
      git_cli.instance_variable_get(:@head_by_path)[worktree] = 'splithead'
      git_cli.instance_variable_set(:@cherry_pick_in_progress, true)
      git_cli.instance_variable_set(:@cherry_pick_head, 'descsha')

      store = PatchUtil::Git::RewriteStateStore.new(git_dir: git_dir)
      store.record_failure(
        PatchUtil::Git::RewriteStateStore::State.new(
          branch: 'main',
          target_sha: 'targetsha',
          head_sha: 'headsha',
          backup_ref: 'refs/patch_util-backups/main/fake',
          worktree_path: worktree,
          status: 'failed',
          message: 'git cherry-pick failed for descsha: boom',
          created_at: Time.now.utc.iso8601,
          pending_revisions: ['descsha']
        )
      )

      result = described_class.new(git_cli: git_cli, applier: FakeApplier.new).continue_rewrite(repo_path: dir)

      result.branch.should
      result.old_head.should
      result.new_head.should
      git_cli.continued_cherry_picks.should
      git_cli.updated_refs.last.should
      git_cli.removed_worktrees.should
      [worktree]
      store.find_branch('main').should be_nil
    end
  end

  it 'reports retained rewrite status details' do
    Dir.mktmpdir do |dir|
      git_dir = File.join(dir, '.git')
      FileUtils.mkdir_p(git_dir)
      git_cli = FakeGitCli.new(git_dir: git_dir)
      worktree = File.join(git_dir, 'patch_util', 'rewrite-worktrees', 'retained-status')
      FileUtils.mkdir_p(worktree)
      git_cli.instance_variable_get(:@head_by_path)[worktree] = 'splithead'
      git_cli.instance_variable_set(:@cherry_pick_in_progress, true)
      git_cli.instance_variable_set(:@cherry_pick_head, 'descsha')

      PatchUtil::Git::RewriteStateStore.new(git_dir: git_dir).record_failure(
        PatchUtil::Git::RewriteStateStore::State.new(
          branch: 'main',
          target_sha: 'targetsha',
          head_sha: 'headsha',
          backup_ref: 'refs/patch_util-backups/main/fake',
          worktree_path: worktree,
          status: 'failed',
          message: 'git cherry-pick failed for descsha: boom',
          created_at: Time.now.utc.iso8601,
          pending_revisions: %w[descsha later]
        )
      )

      status = described_class.new(git_cli: git_cli, applier: FakeApplier.new).status(repo_path: dir)

      status.branch.should
      status.head_sha.should
      status.head_matches.should
      status.worktree_exists.should
      status.worktree_clean.should
      status.cherry_pick_in_progress.should
      status.current_revision.should
      status.unresolved_paths.should
      status.conflict_marker_details.should
      status.state.pending_revisions.should == %w[descsha later]
    end
  end

  it 'restores the current branch from the recorded backup ref and clears retained state' do
    Dir.mktmpdir do |dir|
      git_dir = File.join(dir, '.git')
      FileUtils.mkdir_p(git_dir)
      backup_ref = 'refs/patch_util-backups/main/fake-restore'
      git_cli = FakeGitCli.new(git_dir: git_dir, rev_parse_map: { backup_ref => 'backupsha' })
      git_cli.instance_variable_get(:@head_by_path)[dir] = 'movedsha'
      worktree = File.join(git_dir, 'patch_util', 'rewrite-worktrees', 'retained-restore')
      FileUtils.mkdir_p(worktree)

      store = PatchUtil::Git::RewriteStateStore.new(git_dir: git_dir)
      store.record_failure(
        PatchUtil::Git::RewriteStateStore::State.new(
          branch: 'main',
          target_sha: 'targetsha',
          head_sha: 'headsha',
          backup_ref: backup_ref,
          worktree_path: worktree,
          status: 'failed',
          message: 'previous failure',
          created_at: Time.now.utc.iso8601,
          pending_revisions: ['descsha']
        )
      )

      result = described_class.new(git_cli: git_cli, applier: FakeApplier.new).restore_rewrite(repo_path: dir)

      result.branch.should
      result.old_head.should
      result.restored_head.should
      result.backup_ref.should
      result.worktree_path.should
      result.worktree_removed.should
      git_cli.hard_resets.should
      [[dir, 'backupsha']]
      git_cli.removed_worktrees.should
      [worktree]
      File.directory?(worktree).should
      store.find_branch('main').should be_nil
    end
  end

  it 'fails restore when the backup ref no longer exists and keeps retained state' do
    Dir.mktmpdir do |dir|
      git_dir = File.join(dir, '.git')
      FileUtils.mkdir_p(git_dir)
      backup_ref = 'refs/patch_util-backups/main/missing'
      git_cli = FakeGitCli.new(git_dir: git_dir, missing_revisions: [backup_ref])
      worktree = File.join(git_dir, 'patch_util', 'rewrite-worktrees', 'retained-missing-backup')
      FileUtils.mkdir_p(worktree)

      store = PatchUtil::Git::RewriteStateStore.new(git_dir: git_dir)
      store.record_failure(
        PatchUtil::Git::RewriteStateStore::State.new(
          branch: 'main',
          target_sha: 'targetsha',
          head_sha: 'headsha',
          backup_ref: backup_ref,
          worktree_path: worktree,
          status: 'failed',
          message: 'previous failure',
          created_at: Time.now.utc.iso8601,
          pending_revisions: ['descsha']
        )
      )

      proc do
        described_class.new(git_cli: git_cli, applier: FakeApplier.new).restore_rewrite(repo_path: dir)
      end.should raise_error(PatchUtil::ValidationError, /backup ref #{Regexp.escape(backup_ref)} no longer exists/)

      git_cli.hard_resets.should
      git_cli.removed_worktrees.should
      store.find_branch('main').backup_ref.should == backup_ref
    end
  end

  it 'suggests restore-rewrite when retained state no longer matches the current head' do
    Dir.mktmpdir do |dir|
      git_dir = File.join(dir, '.git')
      FileUtils.mkdir_p(git_dir)
      git_cli = FakeGitCli.new(git_dir: git_dir)
      git_cli.instance_variable_get(:@head_by_path)[dir] = 'movedsha'
      worktree = File.join(git_dir, 'patch_util', 'rewrite-worktrees', 'retained-head-mismatch')
      FileUtils.mkdir_p(worktree)

      PatchUtil::Git::RewriteStateStore.new(git_dir: git_dir).record_failure(
        PatchUtil::Git::RewriteStateStore::State.new(
          branch: 'main',
          target_sha: 'targetsha',
          head_sha: 'headsha',
          backup_ref: 'refs/patch_util-backups/main/fake-restore-guidance',
          worktree_path: worktree,
          status: 'failed',
          message: 'previous failure',
          created_at: Time.now.utc.iso8601,
          pending_revisions: ['descsha']
        )
      )

      status = described_class.new(git_cli: git_cli, applier: FakeApplier.new).status(repo_path: dir)

      status.head_matches.should
      described_class.new(git_cli: git_cli, applier: FakeApplier.new).next_action(status)
                     .should == 'run restore-rewrite before continuing; branch head changed'
    end
  end

  it 'adds rewrite-status guidance when continue fails again' do
    Dir.mktmpdir do |dir|
      git_dir = File.join(dir, '.git')
      FileUtils.mkdir_p(git_dir)
      git_cli = FakeGitCli.new(git_dir: git_dir, fail_on_cherry_pick: true)
      worktree = File.join(git_dir, 'patch_util', 'rewrite-worktrees', 'retained-fail-again')
      FileUtils.mkdir_p(worktree)
      git_cli.instance_variable_get(:@head_by_path)[worktree] = 'splithead'

      store = PatchUtil::Git::RewriteStateStore.new(git_dir: git_dir)
      store.record_failure(
        PatchUtil::Git::RewriteStateStore::State.new(
          branch: 'main',
          target_sha: 'targetsha',
          head_sha: 'headsha',
          backup_ref: 'refs/patch_util-backups/main/fake',
          worktree_path: worktree,
          status: 'failed',
          message: 'previous failure',
          created_at: Time.now.utc.iso8601,
          pending_revisions: ['descsha']
        )
      )

      error = nil
      begin
        described_class.new(git_cli: git_cli, applier: FakeApplier.new).continue_rewrite(repo_path: dir)
      rescue PatchUtil::Error => e
        error = e
      end

      error.should_not be_nil
      error.message.should include('next step: run rewrite-status to inspect the retained state before continuing or aborting')
      store.find_branch('main').pending_revisions.should == ['descsha']
    end
  end

  it 'reports unresolved paths in status and continue failure guidance' do
    Dir.mktmpdir do |dir|
      git_dir = File.join(dir, '.git')
      FileUtils.mkdir_p(git_dir)
      git_cli = FakeGitCli.new(git_dir: git_dir, fail_on_cherry_pick: true)
      worktree = File.join(git_dir, 'patch_util', 'rewrite-worktrees', 'retained-conflicts')
      FileUtils.mkdir_p(worktree)
      git_cli.instance_variable_get(:@head_by_path)[worktree] = 'splithead'
      git_cli.instance_variable_set(:@unresolved_paths, ['example.rb', 'lib/extra.rb'])

      store = PatchUtil::Git::RewriteStateStore.new(git_dir: git_dir)
      store.record_failure(
        PatchUtil::Git::RewriteStateStore::State.new(
          branch: 'main',
          target_sha: 'targetsha',
          head_sha: 'headsha',
          backup_ref: 'refs/patch_util-backups/main/fake',
          worktree_path: worktree,
          status: 'failed',
          message: 'previous failure',
          created_at: Time.now.utc.iso8601,
          pending_revisions: ['descsha']
        )
      )

      status = described_class.new(git_cli: git_cli, applier: FakeApplier.new).status(repo_path: dir)
      status.unresolved_paths.should
      described_class.new(git_cli: git_cli, applier: FakeApplier.new).next_action(status)
                     .should

      error = nil
      begin
        described_class.new(git_cli: git_cli, applier: FakeApplier.new).continue_rewrite(repo_path: dir)
      rescue PatchUtil::Error => e
        error = e
      end

      error.should_not be_nil
      error.message.should include('unresolved paths: example.rb, lib/extra.rb')
      error.message.should include('next step: resolve the listed paths in the retained worktree, then run rewrite-status or continue-rewrite')
    end
  end

  it 'reports conflict-marker details and points users to rewrite-conflicts' do
    Dir.mktmpdir do |dir|
      git_dir = File.join(dir, '.git')
      FileUtils.mkdir_p(git_dir)
      git_cli = FakeGitCli.new(git_dir: git_dir)
      worktree = File.join(git_dir, 'patch_util', 'rewrite-worktrees', 'retained-markers')
      FileUtils.mkdir_p(worktree)
      git_cli.instance_variable_get(:@head_by_path)[worktree] = 'splithead'
      git_cli.instance_variable_set(
        :@conflict_marker_details,
        [
          PatchUtil::Git::Cli::ConflictMarkerDetail.new(
            path: 'example.rb',
            marker_count: 1,
            first_marker_line: 10,
            excerpt: "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> topic"
          )
        ]
      )

      PatchUtil::Git::RewriteStateStore.new(git_dir: git_dir).record_failure(
        PatchUtil::Git::RewriteStateStore::State.new(
          branch: 'main',
          target_sha: 'targetsha',
          head_sha: 'headsha',
          backup_ref: 'refs/patch_util-backups/main/fake',
          worktree_path: worktree,
          status: 'failed',
          message: 'previous failure',
          created_at: Time.now.utc.iso8601,
          pending_revisions: ['descsha']
        )
      )

      status = described_class.new(git_cli: git_cli, applier: FakeApplier.new).status(repo_path: dir)

      status.conflict_marker_details.map(&:path).should
      described_class.new(git_cli: git_cli, applier: FakeApplier.new).next_action(status)
                     .should == 'inspect conflict markers with rewrite-conflicts, resolve them in the retained worktree, then run continue-rewrite'
    end
  end

  it 'resolves retained unresolved paths by choosing a side and staging them' do
    Dir.mktmpdir do |dir|
      git_dir = File.join(dir, '.git')
      FileUtils.mkdir_p(git_dir)
      git_cli = FakeGitCli.new(git_dir: git_dir)
      worktree = File.join(git_dir, 'patch_util', 'rewrite-worktrees', 'retained-resolve')
      FileUtils.mkdir_p(worktree)
      git_cli.instance_variable_get(:@head_by_path)[worktree] = 'splithead'
      git_cli.instance_variable_set(:@unresolved_paths, %w[example.rb lib/extra.rb])

      PatchUtil::Git::RewriteStateStore.new(git_dir: git_dir).record_failure(
        PatchUtil::Git::RewriteStateStore::State.new(
          branch: 'main',
          target_sha: 'targetsha',
          head_sha: 'headsha',
          backup_ref: 'refs/patch_util-backups/main/fake',
          worktree_path: worktree,
          status: 'failed',
          message: 'previous failure',
          created_at: Time.now.utc.iso8601,
          pending_revisions: ['descsha']
        )
      )

      result = described_class.new(git_cli: git_cli, applier: FakeApplier.new).resolve_conflicts(
        repo_path: dir,
        side: 'ours',
        paths: ['example.rb'],
        all_unresolved: false
      )

      result.side.should
      result.resolved_paths.should
      result.remaining_unresolved_paths.should
      git_cli.checked_out_sides.should
      git_cli.added_paths.should == [['example.rb']]
    end
  end

  it 'resolves one retained conflict block at a time' do
    Dir.mktmpdir do |dir|
      git_dir = File.join(dir, '.git')
      FileUtils.mkdir_p(git_dir)
      git_cli = FakeGitCli.new(git_dir: git_dir)
      worktree = File.join(git_dir, 'patch_util', 'rewrite-worktrees', 'retained-blocks')
      FileUtils.mkdir_p(worktree)
      git_cli.instance_variable_get(:@head_by_path)[worktree] = 'splithead'
      git_cli.instance_variable_set(
        :@conflict_marker_details,
        [
          PatchUtil::Git::Cli::ConflictMarkerDetail.new(
            path: 'example.rb',
            marker_count: 2,
            first_marker_line: 5,
            excerpt: "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> topic"
          )
        ]
      )

      PatchUtil::Git::RewriteStateStore.new(git_dir: git_dir).record_failure(
        PatchUtil::Git::RewriteStateStore::State.new(
          branch: 'main',
          target_sha: 'targetsha',
          head_sha: 'headsha',
          backup_ref: 'refs/patch_util-backups/main/fake',
          worktree_path: worktree,
          status: 'failed',
          message: 'previous failure',
          created_at: Time.now.utc.iso8601,
          pending_revisions: ['descsha']
        )
      )

      result = described_class.new(git_cli: git_cli, applier: FakeApplier.new).resolve_conflict_block(
        repo_path: dir,
        path: 'example.rb',
        block_id: 1,
        side: 'theirs'
      )

      result.path.should
      result.block_id.should
      result.side.should
      result.staged.should
      git_cli.resolved_blocks.should == [['example.rb', 1, 'theirs']]
    end
  end

  it 'resolves one retained conflict block with the ancestor side' do
    Dir.mktmpdir do |dir|
      git_dir = File.join(dir, '.git')
      FileUtils.mkdir_p(git_dir)
      git_cli = FakeGitCli.new(git_dir: git_dir)
      worktree = File.join(git_dir, 'patch_util', 'rewrite-worktrees', 'retained-block-ancestor')
      FileUtils.mkdir_p(worktree)
      git_cli.instance_variable_get(:@head_by_path)[worktree] = 'splithead'
      git_cli.instance_variable_set(
        :@conflict_marker_details,
        [
          PatchUtil::Git::Cli::ConflictMarkerDetail.new(
            path: 'example.rb',
            marker_count: 1,
            first_marker_line: 5,
            excerpt: "<<<<<<< HEAD\nours\n||||||| base\nancestor\n=======\ntheirs\n>>>>>>> topic"
          )
        ]
      )

      PatchUtil::Git::RewriteStateStore.new(git_dir: git_dir).record_failure(
        PatchUtil::Git::RewriteStateStore::State.new(
          branch: 'main',
          target_sha: 'targetsha',
          head_sha: 'headsha',
          backup_ref: 'refs/patch_util-backups/main/fake',
          worktree_path: worktree,
          status: 'failed',
          message: 'previous failure',
          created_at: Time.now.utc.iso8601,
          pending_revisions: ['descsha']
        )
      )

      result = described_class.new(git_cli: git_cli, applier: FakeApplier.new).resolve_conflict_block(
        repo_path: dir,
        path: 'example.rb',
        block_id: 1,
        side: 'ancestor'
      )

      result.side.should
      result.staged.should
      git_cli.resolved_blocks.should == [['example.rb', 1, 'ancestor']]
    end
  end

  it 'reports retained conflict blocks with separate side bodies' do
    Dir.mktmpdir do |dir|
      git_dir = File.join(dir, '.git')
      FileUtils.mkdir_p(git_dir)
      git_cli = FakeGitCli.new(git_dir: git_dir)
      worktree = File.join(git_dir, 'patch_util', 'rewrite-worktrees', 'retained-block-detail')
      FileUtils.mkdir_p(worktree)
      git_cli.instance_variable_get(:@head_by_path)[worktree] = 'splithead'
      git_cli.instance_variable_set(
        :@conflict_marker_details,
        [
          PatchUtil::Git::Cli::ConflictMarkerDetail.new(
            path: 'example.rb',
            marker_count: 1,
            first_marker_line: 5,
            excerpt: "<<<<<<< HEAD\nours\n||||||| base\nancestor\n=======\ntheirs\n>>>>>>> topic"
          )
        ]
      )

      PatchUtil::Git::RewriteStateStore.new(git_dir: git_dir).record_failure(
        PatchUtil::Git::RewriteStateStore::State.new(
          branch: 'main',
          target_sha: 'targetsha',
          head_sha: 'headsha',
          backup_ref: 'refs/patch_util-backups/main/fake',
          worktree_path: worktree,
          status: 'failed',
          message: 'previous failure',
          created_at: Time.now.utc.iso8601,
          pending_revisions: ['descsha']
        )
      )

      result = described_class.new(git_cli: git_cli, applier: FakeApplier.new).conflict_blocks(
        repo_path: dir,
        paths: ['example.rb']
      )

      result.branch.should
      result.worktree_path.should
      result.blocks.length.should
      result.blocks.first.path.should
      result.blocks.first.ancestor.should
      result.blocks.first.ours.should
      result.blocks.first.theirs.should == 'theirs'
    end
  end

  it 'exports and reapplies an edited retained conflict block template' do
    Dir.mktmpdir do |dir|
      git_dir = File.join(dir, '.git')
      FileUtils.mkdir_p(git_dir)
      git_cli = FakeGitCli.new(git_dir: git_dir)
      worktree = File.join(git_dir, 'patch_util', 'rewrite-worktrees', 'retained-edit-block')
      FileUtils.mkdir_p(worktree)
      git_cli.instance_variable_get(:@head_by_path)[worktree] = 'splithead'
      git_cli.instance_variable_set(
        :@conflict_marker_details,
        [
          PatchUtil::Git::Cli::ConflictMarkerDetail.new(
            path: 'example.rb',
            marker_count: 1,
            first_marker_line: 5,
            excerpt: "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> topic"
          )
        ]
      )

      PatchUtil::Git::RewriteStateStore.new(git_dir: git_dir).record_failure(
        PatchUtil::Git::RewriteStateStore::State.new(
          branch: 'main',
          target_sha: 'targetsha',
          head_sha: 'headsha',
          backup_ref: 'refs/patch_util-backups/main/fake',
          worktree_path: worktree,
          status: 'failed',
          message: 'previous failure',
          created_at: Time.now.utc.iso8601,
          pending_revisions: ['descsha']
        )
      )

      template_path = File.join(dir, 'edited-block.txt')
      rewriter = described_class.new(git_cli: git_cli, applier: FakeApplier.new)
      export_result = rewriter.export_conflict_block(repo_path: dir, path: 'example.rb', block_id: 1,
                                                     output_path: template_path)
      apply_result = rewriter.apply_conflict_block_edit(repo_path: dir, path: 'example.rb', block_id: 1,
                                                        input_path: template_path)

      export_result.output_path.should
      File.expand_path(template_path)
      apply_result.input_path.should
      File.expand_path(template_path)
      apply_result.staged.should
      git_cli.exported_blocks.should
      [['example.rb', 1, File.expand_path(template_path)]]
      git_cli.applied_block_edits.should == [['example.rb', 1, File.expand_path(template_path)]]
    end
  end

  it 'rejects edited templates with mismatched path metadata' do
    Dir.mktmpdir do |dir|
      git_dir = File.join(dir, '.git')
      FileUtils.mkdir_p(git_dir)
      real_git_cli = PatchUtil::Git::Cli.new
      worktree = File.join(dir, 'retained-worktree')
      FileUtils.mkdir_p(worktree)
      File.write(
        File.join(worktree, 'example.rb'),
        [
          'function a() {',
          '<<<<<<< HEAD',
          '  ours();',
          '=======',
          '  theirs();',
          '>>>>>>> topic',
          '}'
        ].join("\n") + "\n"
      )

      template_path = File.join(dir, 'edited-block.txt')
      real_git_cli.export_conflict_block_template(worktree, file_path: 'example.rb', block_id: 1,
                                                            output_path: template_path)
      File.write(template_path, File.read(template_path).sub('# path: example.rb', '# path: other.rb'))

      proc do
        real_git_cli.apply_conflict_block_edit(worktree, file_path: 'example.rb', block_id: 1,
                                                         input_path: template_path)
      end.should raise_error(PatchUtil::ValidationError, /does not match requested path/)
    end
  end

  it 'exports and reapplies an edited retained conflict block session template' do
    Dir.mktmpdir do |dir|
      git_dir = File.join(dir, '.git')
      FileUtils.mkdir_p(git_dir)
      git_cli = FakeGitCli.new(git_dir: git_dir)
      worktree = File.join(git_dir, 'patch_util', 'rewrite-worktrees', 'retained-edit-session')
      FileUtils.mkdir_p(worktree)
      git_cli.instance_variable_get(:@head_by_path)[worktree] = 'splithead'
      git_cli.instance_variable_set(
        :@conflict_marker_details,
        [
          PatchUtil::Git::Cli::ConflictMarkerDetail.new(
            path: 'example.rb',
            marker_count: 2,
            first_marker_line: 5,
            excerpt: "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> topic"
          )
        ]
      )

      PatchUtil::Git::RewriteStateStore.new(git_dir: git_dir).record_failure(
        PatchUtil::Git::RewriteStateStore::State.new(
          branch: 'main',
          target_sha: 'targetsha',
          head_sha: 'headsha',
          backup_ref: 'refs/patch_util-backups/main/fake',
          worktree_path: worktree,
          status: 'failed',
          message: 'previous failure',
          created_at: Time.now.utc.iso8601,
          pending_revisions: ['descsha']
        )
      )

      template_path = File.join(dir, 'edited-session.txt')
      rewriter = described_class.new(git_cli: git_cli, applier: FakeApplier.new)
      export_result = rewriter.export_conflict_block_session(repo_path: dir, paths: ['example.rb'],
                                                             output_path: template_path)
      apply_result = rewriter.apply_conflict_block_session_edit(repo_path: dir, input_path: template_path)

      export_result.output_path.should
      File.expand_path(template_path)
      export_result.blocks.length.should
      export_result.files.should
      apply_result.input_path.should
      File.expand_path(template_path)
      apply_result.applied_blocks.length.should
      apply_result.staged_paths.should
      apply_result.files.should
      git_cli.exported_sessions.should
      [[['example.rb'], File.expand_path(template_path)]]
      git_cli.applied_session_edits.should == [File.expand_path(template_path)]
    end
  end

  it 'rejects edited block session templates with duplicate block identities' do
    Dir.mktmpdir do |dir|
      real_git_cli = PatchUtil::Git::Cli.new
      worktree = File.join(dir, 'retained-worktree')
      FileUtils.mkdir_p(worktree)
      File.write(
        File.join(worktree, 'example.rb'),
        [
          'function a() {',
          '<<<<<<< HEAD',
          '  ours_one();',
          '=======',
          '  theirs_one();',
          '>>>>>>> topic',
          '  stable();',
          '<<<<<<< HEAD',
          '  ours_two();',
          '=======',
          '  theirs_two();',
          '>>>>>>> topic',
          '}'
        ].join("\n") + "\n"
      )

      session_path = File.join(dir, 'edited-session.txt')
      real_git_cli.export_conflict_block_session_template(worktree, file_paths: ['example.rb'],
                                                                    output_path: session_path)
      duplicated = File.read(session_path).sub('# block id: 2', '# block id: 1')
      File.write(session_path, duplicated)

      proc do
        real_git_cli.apply_conflict_block_session_edit(worktree, input_path: session_path)
      end.should raise_error(PatchUtil::ValidationError, /repeats block 1 for example\.rb/)
    end
  end

  it 'rejects edited block session templates whose declared block count does not match' do
    Dir.mktmpdir do |dir|
      real_git_cli = PatchUtil::Git::Cli.new
      worktree = File.join(dir, 'retained-worktree')
      FileUtils.mkdir_p(worktree)
      File.write(
        File.join(worktree, 'example.rb'),
        [
          'function a() {',
          '<<<<<<< HEAD',
          '  ours();',
          '=======',
          '  theirs();',
          '>>>>>>> topic',
          '}'
        ].join("\n") + "\n"
      )

      session_path = File.join(dir, 'edited-session.txt')
      real_git_cli.export_conflict_block_session_template(worktree, file_paths: ['example.rb'],
                                                                    output_path: session_path)
      wrong_count = File.read(session_path).sub('# block count: 1', '# block count: 2')
      File.write(session_path, wrong_count)

      proc do
        real_git_cli.apply_conflict_block_session_edit(worktree, input_path: session_path)
      end.should raise_error(PatchUtil::ValidationError, /declares 2 blocks but contains 1 blocks/)
    end
  end

  it 'rejects edited block session templates that reference missing blocks before applying' do
    Dir.mktmpdir do |dir|
      real_git_cli = PatchUtil::Git::Cli.new
      worktree = File.join(dir, 'retained-worktree')
      FileUtils.mkdir_p(worktree)
      File.write(
        File.join(worktree, 'example.rb'),
        [
          'function a() {',
          '<<<<<<< HEAD',
          '  ours();',
          '=======',
          '  theirs();',
          '>>>>>>> topic',
          '}'
        ].join("\n") + "\n"
      )

      session_path = File.join(dir, 'edited-session.txt')
      real_git_cli.export_conflict_block_session_template(worktree, file_paths: ['example.rb'],
                                                                    output_path: session_path)
      wrong_block = File.read(session_path).sub('# block id: 1', '# block id: 2')
      File.write(session_path, wrong_block)

      proc do
        real_git_cli.apply_conflict_block_session_edit(worktree, input_path: session_path)
      end.should raise_error(PatchUtil::ValidationError, /references missing block 2 for example\.rb/)
      File.read(File.join(worktree, 'example.rb')).should include('<<<<<<< HEAD')
    end
  end

  it 'summarizes retained session blocks by file' do
    Dir.mktmpdir do |dir|
      real_git_cli = PatchUtil::Git::Cli.new
      repo_dir = File.join(dir, 'repo')
      FileUtils.mkdir_p(repo_dir)
      run_git(repo_dir, %w[init])
      branch = run_git(repo_dir, %w[branch --show-current]).strip
      git_dir = run_git(repo_dir, %w[rev-parse --absolute-git-dir]).strip
      worktree = File.join(git_dir, 'patch_util', 'rewrite-worktrees', 'retained-session-summary')
      FileUtils.mkdir_p(worktree)
      File.write(
        File.join(worktree, 'example.rb'),
        [
          'function a() {',
          '<<<<<<< HEAD',
          '  ours_one();',
          '=======',
          '  theirs_one();',
          '>>>>>>> topic',
          '  stable();',
          '<<<<<<< HEAD',
          '  ours_two();',
          '||||||| base',
          '  ancestor_two();',
          '=======',
          '  theirs_two();',
          '>>>>>>> topic',
          '}'
        ].join("\n") + "\n"
      )
      FileUtils.mkdir_p(File.join(worktree, 'lib'))
      File.write(
        File.join(worktree, 'lib', 'extra.rb'),
        [
          'module Extra',
          '<<<<<<< HEAD',
          '  ours();',
          '=======',
          '  theirs();',
          '>>>>>>> topic',
          'end'
        ].join("\n") + "\n"
      )

      write_retained_state(
        git_dir: git_dir,
        branch: branch,
        target_sha: 'targetsha',
        head_sha: 'headsha',
        worktree_path: worktree,
        backup_ref: "refs/patch_util-backups/#{branch}/fake-summary"
      )

      summary = described_class.new(git_cli: real_git_cli, applier: FakeApplier.new)
                               .conflict_block_session_summary(repo_path: repo_dir)

      summary.branch.should
      summary.worktree_path.should
      summary.blocks.length.should
      summary.files.keys.should
      summary.files['example.rb'][:block_ids].should
      summary.files['example.rb'][:block_count].should
      summary.files['example.rb'][:has_ancestor].should
      summary.files['lib/extra.rb'][:block_ids].should
      summary.files['lib/extra.rb'][:block_count].should
      summary.files['lib/extra.rb'][:has_ancestor].should == false
    end
  end
end
