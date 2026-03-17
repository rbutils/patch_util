# frozen_string_literal: true

RSpec.describe PatchUtil::CLI do
  it 'plans, overlays, and applies through the CLI' do
    Dir.mktmpdir do |dir|
      patch_path = File.join(dir, 'sample.diff')
      plan_path = File.join(dir, 'sample.plan.json')
      output_dir = File.join(dir, 'out')
      File.write(patch_path, PatchUtil::SpecHelpers::SAMPLE_PATCH)

      plan_output = capture_stdout do
        described_class.start([
                                'split', 'plan',
                                '--patch', patch_path,
                                '--plan', plan_path,
                                'remove old', 'a1',
                                'add new', 'a2'
                              ])
      end

      File.exist?(plan_path).should
      plan_output.should include('saved 2 chunks')

      inspect_output = capture_stdout do
        described_class.start([
                                'split', 'inspect',
                                '--patch', patch_path,
                                '--plan', plan_path
                              ])
      end

      inspect_output.should include('a1 [remove old]')
      inspect_output.should include('a2 [add new]')

      apply_output = capture_stdout do
        described_class.start([
                                'split', 'apply',
                                '--patch', patch_path,
                                '--plan', plan_path,
                                '--output-dir', output_dir
                              ])
      end

      File.exist?(File.join(output_dir, '0001-remove-old.patch')).should
      File.exist?(File.join(output_dir, '0002-add-new.patch')).should
      apply_output.should include('remove old')
      apply_output.should include('add new')
    end
  end

  it 'renders a compact inspect summary when requested' do
    Dir.mktmpdir do |dir|
      patch_path = File.join(dir, 'new-file.diff')
      plan_path = File.join(dir, 'new-file.plan.json')
      File.write(patch_path, PatchUtil::SpecHelpers::NEW_FILE_PATCH)

      capture_stdout do
        described_class.start([
                                'split', 'plan',
                                '--patch', patch_path,
                                '--plan', plan_path,
                                'first lines', 'a1-a2',
                                'last line', 'a3'
                              ])
      end

      inspect_output = capture_stdout do
        described_class.start([
                                'split', 'inspect',
                                '--patch', patch_path,
                                '--plan', plan_path,
                                '--compact'
                              ])
      end

      inspect_output.should include('--- /dev/null')
      inspect_output.should include('+++ b/new_file.rb')
      inspect_output.should include('== File Index ==')
      inspect_output.should include('b/new_file.rb (1 hunk, 3 changes): a(text, 3 changes: a1-a2 [first lines], a3 [last line])')
      inspect_output.should include('a text @@ -0,0 +1,3 @@: a1-a2 [first lines], a3 [last line]')
      inspect_output.should_not include('+line one')
      inspect_output.should_not include('+line two')
    end
  end

  it 'keeps compact detail order stable while summarizing index entries' do
    Dir.mktmpdir do |dir|
      patch_path = File.join(dir, 'offset.diff')
      plan_path = File.join(dir, 'offset.plan.json')
      File.write(patch_path, PatchUtil::SpecHelpers::OFFSET_PATCH)

      inspect_output = capture_stdout do
        described_class.start([
                                'split', 'inspect',
                                '--patch', patch_path,
                                '--plan', plan_path,
                                '--compact'
                              ])
      end

      inspect_output.should include('b/example.rb (2 hunks, 2 changes): a(text, 1 change: a1); b(text, 1 change: b1)')
      inspect_output.index('a text @@ -1,4 +1,3 @@: a1').should be < inspect_output.index('b text @@ -10,4 +9,5 @@: b1')
    end
  end

  it 'expands selected hunks inside compact inspect output' do
    Dir.mktmpdir do |dir|
      patch_path = File.join(dir, 'rename.diff')
      File.write(patch_path, PatchUtil::SpecHelpers::RENAME_PATCH)

      inspect_output = capture_stdout do
        described_class.start([
                                'split', 'inspect',
                                '--patch', patch_path,
                                '--plan', File.join(dir, 'rename.plan.json'),
                                '--compact',
                                '--expand', 'b'
                              ])
      end

      inspect_output.should include('expanded hunks: b')
      inspect_output.should include('a operation: a1 =rename lib/old.rb -> lib/new.rb (71%)')
      inspect_output.should include('b text @@ -1,3 +1,3 @@: b1-b2 [expanded]')
      inspect_output.should include('b1                           -one')
      inspect_output.should include('b2                           +ONE')
      inspect_output.should_not include('a1                           =rename')
    end
  end

  it 'rejects --expand without --compact' do
    Dir.mktmpdir do |dir|
      patch_path = File.join(dir, 'sample.diff')
      File.write(patch_path, PatchUtil::SpecHelpers::SAMPLE_PATCH)

      lambda do
        described_class.start([
                                'split', 'inspect',
                                '--patch', patch_path,
                                '--plan', File.join(dir, 'sample.plan.json'),
                                '--expand', 'a'
                              ])
      end.should raise_error(PatchUtil::ValidationError, /--expand requires --compact/)
    end
  end

  it 'rejects non-hunk selectors in --expand' do
    Dir.mktmpdir do |dir|
      patch_path = File.join(dir, 'sample.diff')
      File.write(patch_path, PatchUtil::SpecHelpers::SAMPLE_PATCH)

      lambda do
        described_class.start([
                                'split', 'inspect',
                                '--patch', patch_path,
                                '--plan', File.join(dir, 'sample.plan.json'),
                                '--compact',
                                '--expand', 'a1-a2'
                              ])
      end.should raise_error(PatchUtil::ValidationError, /--expand only accepts whole-hunk labels/)
    end
  end

  it 'accepts hunk ranges in --expand' do
    Dir.mktmpdir do |dir|
      patch_path = File.join(dir, 'offset.diff')
      File.write(patch_path, PatchUtil::SpecHelpers::OFFSET_PATCH)

      inspect_output = capture_stdout do
        described_class.start([
                                'split', 'inspect',
                                '--patch', patch_path,
                                '--plan', File.join(dir, 'offset.plan.json'),
                                '--compact',
                                '--expand', 'a-b'
                              ])
      end

      inspect_output.should include('expanded hunks: a, b')
      inspect_output.should include('a text @@ -1,4 +1,3 @@: a1 [expanded]')
      inspect_output.should include('b text @@ -10,4 +9,5 @@: b1 [expanded]')
      inspect_output.should include('a1                           -  do_something();')
      inspect_output.should include('b1                           +  do_other();')
    end
  end

  it 'rejects unknown hunk labels in --expand' do
    Dir.mktmpdir do |dir|
      patch_path = File.join(dir, 'sample.diff')
      File.write(patch_path, PatchUtil::SpecHelpers::SAMPLE_PATCH)

      lambda do
        described_class.start([
                                'split', 'inspect',
                                '--patch', patch_path,
                                '--plan', File.join(dir, 'sample.plan.json'),
                                '--compact',
                                '--expand', 'z'
                              ])
      end.should raise_error(PatchUtil::ValidationError, /unknown hunk label for --expand: z/)
    end
  end

  it 'uses git commit sources with default repo-local plan storage' do
    create_git_repo_with_patch do |repo_dir|
      commit_sha = run_git(repo_dir, %w[rev-parse HEAD]).strip
      git_plan_path = File.join(repo_dir, '.git', 'patch_util', 'plans.json')
      output_dir = File.join(repo_dir, 'out')

      plan_output = capture_stdout do
        described_class.start([
                                'split', 'plan',
                                '--repo', repo_dir,
                                '--commit', commit_sha,
                                'remove old', 'a1',
                                'add new', 'a2'
                              ])
      end

      File.exist?(git_plan_path).should
      plan_output.should include(git_plan_path)

      inspect_output = capture_stdout do
        described_class.start([
                                'split', 'inspect',
                                '--repo', repo_dir,
                                '--commit', commit_sha
                              ])
      end

      inspect_output.should include('a1 [remove old]')
      inspect_output.should include('a2 [add new]')

      apply_output = capture_stdout do
        described_class.start([
                                'split', 'apply',
                                '--repo', repo_dir,
                                '--commit', commit_sha,
                                '--output-dir', output_dir
                              ])
      end

      File.exist?(File.join(output_dir, '0001-remove-old.patch')).should
      File.exist?(File.join(output_dir, '0002-add-new.patch')).should
      apply_output.should include('remove old')
      apply_output.should include('add new')
    end
  end

  it 'plans and applies split patches for newly added files from a patch file' do
    Dir.mktmpdir do |dir|
      patch_path = File.join(dir, 'new-file.diff')
      plan_path = File.join(dir, 'new-file.plan.json')
      output_dir = File.join(dir, 'out')
      File.write(patch_path, PatchUtil::SpecHelpers::NEW_FILE_PATCH)

      capture_stdout do
        described_class.start([
                                'split', 'plan',
                                '--patch', patch_path,
                                '--plan', plan_path,
                                'first lines', 'a1-a2',
                                'last line', 'a3'
                              ])
      end

      inspect_output = capture_stdout do
        described_class.start([
                                'split', 'inspect',
                                '--patch', patch_path,
                                '--plan', plan_path
                              ])
      end

      inspect_output.should include('a1 [first lines]')
      inspect_output.should include('a3 [last line]')

      capture_stdout do
        described_class.start([
                                'split', 'apply',
                                '--patch', patch_path,
                                '--plan', plan_path,
                                '--output-dir', output_dir
                              ])
      end

      first_patch = File.read(File.join(output_dir, '0001-first-lines.patch'))
      second_patch = File.read(File.join(output_dir, '0002-last-line.patch'))

      first_patch.should include('@@ -0,0 +1,2 @@')
      second_patch.should include('@@ -0,2 +1,3 @@')
    end
  end

  it 'rewrites linear git history by splitting an earlier commit' do
    create_linear_git_repo_for_rewrite do |repo_dir, shas|
      branch = run_git(repo_dir, %w[branch --show-current]).strip

      plan_output = capture_stdout do
        described_class.start([
                                'split', 'plan',
                                '--repo', repo_dir,
                                '--commit', shas[:change],
                                'remove old', 'a1',
                                'add new', 'a2'
                              ])
      end

      plan_output.should include('.git/patch_util/plans.json')

      rewrite_output = capture_stdout do
        described_class.start([
                                'split', 'apply',
                                '--repo', repo_dir,
                                '--commit', shas[:change],
                                '--rewrite'
                              ])
      end

      subjects = run_git(repo_dir, %w[log --format=%s -4 HEAD]).lines(chomp: true)
      subjects.should

      body = run_git(repo_dir, %w[show -s --format=%b HEAD~1])
      body.should include("Split-from: #{shas[:change]}")
      body.should include('Original-subject: change')

      backup_refs = run_git(repo_dir, %w[for-each-ref --format=%(refname) refs/patch_util-backups]).lines(chomp: true)
      backup_refs.length.should
      rewrite_output.should include("rewrote #{branch}:")
      rewrite_output.should include('created remove old')
      rewrite_output.should include('created add new')
      File.read(File.join(repo_dir, 'example.rb')).should include('do_something_else();')
      File.read(File.join(repo_dir, 'example.rb')).should include('function c() {')
      File.exist?(File.join(repo_dir, '.patch_util_emitted')).should
      tree_entries = run_git(repo_dir, %w[ls-tree -r --name-only HEAD])
      tree_entries.should_not include('.patch_util_emitted/')
    end
  end

  it 'preserves original author, committer, and commit trailers when rewriting split commits' do
    create_linear_git_repo_for_rewrite_with_metadata do |repo_dir, shas|
      capture_stdout do
        described_class.start([
                                'split', 'plan',
                                '--repo', repo_dir,
                                '--commit', shas[:change],
                                'remove old', 'a1',
                                'add new', 'a2'
                              ])
      end

      capture_stdout do
        described_class.start([
                                'split', 'apply',
                                '--repo', repo_dir,
                                '--commit', shas[:change],
                                '--rewrite'
                              ])
      end

      author = run_git(repo_dir, ['show', '-s', '--format=%an <%ae>', 'HEAD~1']).strip
      committer = run_git(repo_dir, ['show', '-s', '--format=%cn <%ce>', 'HEAD~1']).strip
      body = run_git(repo_dir, %w[show -s --format=%b HEAD~1])

      author.should
      committer.should
      body.should include('Detailed body for change.')
      body.should include('Co-authored-by: Pair Person <pair@example.com>')
      body.should include('Tested-by: Test Runner <test@example.com>')
      body.should include('Signed-off-by: Patch Util Spec <patch-util-spec@example.com>')
      body.should include("Split-from: #{shas[:change]}")
      body.should include('Original-subject: change')
    end
  end

  it 'rewrites earlier commits even when no git identity is configured in the process environment' do
    create_linear_git_repo_for_rewrite_with_metadata do |repo_dir, shas|
      with_env(
        'GIT_AUTHOR_NAME' => nil,
        'GIT_AUTHOR_EMAIL' => nil,
        'GIT_AUTHOR_DATE' => nil,
        'GIT_COMMITTER_NAME' => nil,
        'GIT_COMMITTER_EMAIL' => nil,
        'GIT_COMMITTER_DATE' => nil,
        'EMAIL' => nil
      ) do
        capture_stdout do
          described_class.start([
                                  'split', 'plan',
                                  '--repo', repo_dir,
                                  '--commit', shas[:change],
                                  'remove old', 'a1',
                                  'add new', 'a2'
                                ])
        end

        capture_stdout do
          described_class.start([
                                  'split', 'apply',
                                  '--repo', repo_dir,
                                  '--commit', shas[:change],
                                  '--rewrite'
                                ])
        end
      end

      author = run_git(repo_dir, ['show', '-s', '--format=%an <%ae>', 'HEAD~1']).strip
      committer = run_git(repo_dir, ['show', '-s', '--format=%cn <%ce>', 'HEAD~1']).strip
      body = run_git(repo_dir, %w[show -s --format=%b HEAD~1])

      author.should
      committer.should
      body.should include("Split-from: #{shas[:change]}")
      body.should include('Original-subject: change')
    end
  end

  it 'rejects rewrite apply when the git worktree is dirty' do
    create_linear_git_repo_for_rewrite do |repo_dir, shas|
      capture_stdout do
        described_class.start([
                                'split', 'plan',
                                '--repo', repo_dir,
                                '--commit', shas[:change],
                                'remove old', 'a1',
                                'add new', 'a2'
                              ])
      end

      original_head = run_git(repo_dir, %w[rev-parse HEAD]).strip
      File.write(File.join(repo_dir, 'scratch.txt'), "dirty\n")

      proc do
        described_class.start([
                                'split', 'apply',
                                '--repo', repo_dir,
                                '--commit', shas[:change],
                                '--rewrite'
                              ])
      end.should raise_error(PatchUtil::ValidationError, /clean worktree/)

      run_git(repo_dir, %w[rev-parse HEAD]).strip.should == original_head
    end
  end

  it 'fails clearly when inspect targets a merge commit' do
    create_git_repo_with_merge_commit do |repo_dir, shas|
      proc do
        described_class.start([
                                'split', 'inspect',
                                '--repo', repo_dir,
                                '--commit', shas[:merge]
                              ])
      end.should raise_error(PatchUtil::ValidationError, /merge commits are not supported yet/)
    end
  end

  it 'inspects git-backed binary commits with real binary patch payloads' do
    create_git_repo_with_binary_commit do |repo_dir, shas|
      inspect_output = capture_stdout do
        described_class.start([
                                'split', 'inspect',
                                '--repo', repo_dir,
                                '--commit', shas[:change]
                              ])
      end

      inspect_output.should include('a1')
      inspect_output.should include('=binary image.bin')
    end
  end

  it 'plans and applies git-backed binary commits to patch files' do
    create_git_repo_with_binary_commit do |repo_dir, shas|
      output_dir = File.join(repo_dir, 'out')

      plan_output = capture_stdout do
        described_class.start([
                                'split', 'plan',
                                '--repo', repo_dir,
                                '--commit', shas[:change],
                                'binary update', 'a'
                              ])
      end

      plan_output.should include('.git/patch_util/plans.json')

      apply_output = capture_stdout do
        described_class.start([
                                'split', 'apply',
                                '--repo', repo_dir,
                                '--commit', shas[:change],
                                '--output-dir', output_dir
                              ])
      end

      patch_path = File.join(output_dir, '0001-binary-update.patch')
      File.exist?(patch_path).should
      patch_text = File.binread(patch_path)
      patch_text.should include('diff --git a/image.bin b/image.bin')
      patch_text.should include('GIT binary patch')
      patch_text.should include('literal 64')
      apply_output.should include("binary update -> #{patch_path}")
    end
  end

  it 'plans and applies git-backed binary add commits to patch files' do
    create_git_repo_with_binary_add_and_delete_commits do |repo_dir, shas|
      output_dir = File.join(repo_dir, 'out-add')

      capture_stdout do
        described_class.start([
                                'split', 'plan',
                                '--repo', repo_dir,
                                '--commit', shas[:add],
                                'add binary', 'a'
                              ])
      end

      apply_output = capture_stdout do
        described_class.start([
                                'split', 'apply',
                                '--repo', repo_dir,
                                '--commit', shas[:add],
                                '--output-dir', output_dir
                              ])
      end

      patch_path = File.join(output_dir, '0001-add-binary.patch')
      patch_text = File.binread(patch_path)
      patch_text.should include('diff --git a/image.bin b/image.bin')
      patch_text.should include('new file mode 100644')
      patch_text.should include('GIT binary patch')
      patch_text.should_not include('--- /dev/null')
      patch_text.should_not include('+++ b/image.bin')
      apply_output.should include("add binary -> #{patch_path}")
    end
  end

  it 'plans and applies git-backed binary delete commits to patch files' do
    create_git_repo_with_binary_add_and_delete_commits do |repo_dir, shas|
      output_dir = File.join(repo_dir, 'out-delete')

      capture_stdout do
        described_class.start([
                                'split', 'plan',
                                '--repo', repo_dir,
                                '--commit', shas[:delete],
                                'delete binary', 'a'
                              ])
      end

      apply_output = capture_stdout do
        described_class.start([
                                'split', 'apply',
                                '--repo', repo_dir,
                                '--commit', shas[:delete],
                                '--output-dir', output_dir
                              ])
      end

      patch_path = File.join(output_dir, '0001-delete-binary.patch')
      patch_text = File.binread(patch_path)
      patch_text.should include('diff --git a/image.bin b/image.bin')
      patch_text.should include('deleted file mode 100644')
      patch_text.should include('GIT binary patch')
      patch_text.should_not include('--- a/image.bin')
      patch_text.should_not include('+++ /dev/null')
      apply_output.should include("delete binary -> #{patch_path}")
    end
  end

  it 'plans and applies git-backed binary rename plus payload commits to patch files' do
    create_git_repo_with_binary_rename_change_commit do |repo_dir, shas|
      output_dir = File.join(repo_dir, 'out-rename')

      inspect_output = capture_stdout do
        described_class.start([
                                'split', 'inspect',
                                '--repo', repo_dir,
                                '--commit', shas[:change]
                              ])
      end

      inspect_output.should include('a1')
      inspect_output.should include('b1')

      capture_stdout do
        described_class.start([
                                'split', 'plan',
                                '--repo', repo_dir,
                                '--commit', shas[:change],
                                'rename binary', 'a',
                                'update binary', 'b'
                              ])
      end

      apply_output = capture_stdout do
        described_class.start([
                                'split', 'apply',
                                '--repo', repo_dir,
                                '--commit', shas[:change],
                                '--output-dir', output_dir
                              ])
      end

      rename_patch_path = File.join(output_dir, '0001-rename-binary.patch')
      update_patch_path = File.join(output_dir, '0002-update-binary.patch')
      rename_patch = File.binread(rename_patch_path)
      update_patch = File.binread(update_patch_path)

      rename_patch.should include('diff --git a/old.bin b/new.bin')
      rename_patch.should include('similarity index 95%')
      rename_patch.should include('rename from old.bin')
      rename_patch.should include('rename to new.bin')
      rename_patch.should_not include('GIT binary patch')

      update_patch.should include('diff --git a/new.bin b/new.bin')
      update_patch.should include('GIT binary patch')
      update_patch.should_not include('rename from old.bin')
      update_patch.should_not include('rename to new.bin')

      apply_output.should include("rename binary -> #{rename_patch_path}")
      apply_output.should include("update binary -> #{update_patch_path}")
    end
  end

  it 'rewrites an earlier git-backed binary commit and replays descendants' do
    create_linear_git_repo_with_binary_rewrite do |repo_dir, shas|
      run_git(repo_dir, %w[rev-parse HEAD^{tree}]).strip

      plan_output = capture_stdout do
        described_class.start([
                                'split', 'plan',
                                '--repo', repo_dir,
                                '--commit', shas[:change],
                                'binary update', 'a'
                              ])
      end

      plan_output.should include('saved 1 chunks')

      rewrite_output = capture_stdout do
        described_class.start([
                                'split', 'apply',
                                '--repo', repo_dir,
                                '--commit', shas[:change],
                                '--rewrite'
                              ])
      end

      rewrite_output.should include('created binary update')
      run_git(repo_dir, %w[rev-parse HEAD^{tree}]).strip.should
      File.binread(File.join(repo_dir, 'image.bin')).should
      shas[:binary_bytes]
      File.read(File.join(repo_dir, 'notes.txt')).should include('follow-up')
      tree_entries = run_git(repo_dir, %w[ls-tree -r --name-only HEAD])
      tree_entries.should include('image.bin')
      tree_entries.should_not include('.patch_util_emitted/')

      body = run_git(repo_dir, %w[show -s --format=%b HEAD~1])
      body.should include("Split-from: #{shas[:change]}")
      body.should include('Original-subject: binary-change')
    end
  end

  it 'rewrites an earlier commit that mixes modifications and new files' do
    create_linear_git_repo_with_new_file_rewrite do |repo_dir, shas|
      inspect_output = capture_stdout do
        described_class.start([
                                'split', 'inspect',
                                '--repo', repo_dir,
                                '--commit', shas[:change]
                              ])
      end

      inspect_output.should include('a1')
      inspect_output.should include('b1')

      plan_output = capture_stdout do
        described_class.start([
                                'split', 'plan',
                                '--repo', repo_dir,
                                '--commit', shas[:change],
                                'modify existing', 'a',
                                'add file', 'b'
                              ])
      end

      plan_output.should include('saved 2 chunks')

      rewrite_output = capture_stdout do
        described_class.start([
                                'split', 'apply',
                                '--repo', repo_dir,
                                '--commit', shas[:change],
                                '--rewrite'
                              ])
      end

      rewrite_output.should include('rewrote master:')
      rewrite_output.should include('created modify existing')
      rewrite_output.should include('created add file')
      File.read(File.join(repo_dir, 'existing.rb')).should include('trailer')
      File.read(File.join(repo_dir, 'lib', 'new_file.rb')).should include('alpha')
      tree_entries = run_git(repo_dir, %w[ls-tree -r --name-only HEAD])
      tree_entries.should include('lib/new_file.rb')
      tree_entries.should_not include('.patch_util_emitted/')
    end
  end

  it 'rejects rewrite when descendant replay would cross a merge commit' do
    create_git_repo_with_earlier_commit_and_merge_descendant do |repo_dir, shas|
      capture_stdout do
        described_class.start([
                                'split', 'plan',
                                '--repo', repo_dir,
                                '--commit', shas[:target],
                                'first change', 'a1',
                                'second change', 'a2'
                              ])
      end

      run_git(repo_dir, %w[rev-parse HEAD]).strip
      proc do
        described_class.start([
                                'split', 'apply',
                                '--repo', repo_dir,
                                '--commit', shas[:target],
                                '--rewrite'
                              ])
      end.should raise_error(PatchUtil::ValidationError,
                             /does not support descendant merge commits yet: #{Regexp.escape(shas[:merge])}/)

      run_git(repo_dir, %w[rev-parse HEAD]).strip.should
      backup_refs = run_git(repo_dir, %w[for-each-ref --format=%(refname) refs/patch_util-backups]).lines(chomp: true)
      backup_refs.should == []
    end
  end
end
