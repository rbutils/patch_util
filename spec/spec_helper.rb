# frozen_string_literal: true

require 'simplecov'

SimpleCov.start do
  enable_coverage :branch
  minimum_coverage 80
end

require 'fileutils'
require 'open3'
require 'stringio'
require 'tmpdir'
require 'patch_util'

module PatchUtil
  module SpecHelpers
    SAMPLE_PATCH = <<~PATCH
      --- a/example.rb
      +++ b/example.rb
      @@ -1,5 +1,5 @@
       function a() {
         var b;
      -  do_something();
      +  do_something_else();
         return true;
       }
    PATCH

    OFFSET_PATCH = <<~PATCH
      --- a/example.rb
      +++ b/example.rb
      @@ -1,4 +1,3 @@
       function a() {
      -  do_something();
         return true;
       }
      @@ -10,4 +9,5 @@
       function b() {
      +  do_other();
         return false;
       }
    PATCH

    NEW_FILE_PATCH = <<~PATCH
      --- /dev/null
      +++ b/new_file.rb
      @@ -0,0 +1,3 @@
      +line one
      +line two
      +line three
    PATCH

    DELETE_FILE_PATCH = <<~PATCH
      --- a/old_file.rb
      +++ /dev/null
      @@ -1,3 +0,0 @@
      -line one
      -line two
      -line three
    PATCH

    RENAME_PATCH = <<~PATCH
      diff --git a/lib/old.rb b/lib/new.rb
      similarity index 71%
      rename from lib/old.rb
      rename to lib/new.rb
      --- a/lib/old.rb
      +++ b/lib/new.rb
      @@ -1,3 +1,3 @@
       alpha
      -one
      +ONE
       two
    PATCH

    RENAME_ONLY_PATCH = <<~PATCH
      diff --git a/lib/old.rb b/lib/new.rb
      similarity index 100%
      rename from lib/old.rb
      rename to lib/new.rb
    PATCH

    COPY_PATCH = <<~PATCH
      diff --git a/lib/old.rb b/lib/new.rb
      similarity index 71%
      copy from lib/old.rb
      copy to lib/new.rb
      --- a/lib/old.rb
      +++ b/lib/new.rb
      @@ -1,3 +1,3 @@
       alpha
      -one
      +ONE
       two
    PATCH

    MODE_PATCH = <<~PATCH
      diff --git a/bin/tool b/bin/tool
      old mode 100644
      new mode 100755
    PATCH

    RENAME_WITH_MODE_PATCH = <<~PATCH
      diff --git a/lib/old.rb b/lib/new.rb
      old mode 100644
      new mode 100755
      similarity index 71%
      rename from lib/old.rb
      rename to lib/new.rb
      --- a/lib/old.rb
      +++ b/lib/new.rb
      @@ -1,3 +1,3 @@
       alpha
      -one
      +ONE
       two
    PATCH

    MIXED_MODIFY_AND_NEW_FILE_PATCH = <<~PATCH
      diff --git a/lib/existing.rb b/lib/existing.rb
      --- a/lib/existing.rb
      +++ b/lib/existing.rb
      @@ -1,2 +1,2 @@
      -old line
      +new line
       same line
      diff --git a/lib/new_file.rb b/lib/new_file.rb
      new file mode 100644
      --- /dev/null
      +++ b/lib/new_file.rb
      @@ -0,0 +1,2 @@
      +alpha
      +beta
    PATCH

    BINARY_PATCH = <<~PATCH
      diff --git a/image.bin b/image.bin
      index c86626638e0bc8cf47ca49bb1525b40e9737ee64..5663091be8ca2b5e57d3c2323a38840a729caf66 100644
      GIT binary patch
      literal 256
      zcmV+b0ssF0{{8&>`uX_x_Vx7h^6~KR?(OXB>gnj`=H=w$;^E-m-rd~W+S%CG*45P0
      z($Ub*&dtor%E`#b#>K?L!ok45zP-G=y1BTwwzaggvaztQuC1)As;Q`_rlq8#qM@Ll
      zo}HYVnwglFmX(x~l97;)j*X0qiiwDahJ}QKf`Nd4etmp<dU<$vc6D@fa&d5PZf$I9
      zYH4U^W@Th!VqsukUR_*UT3J|ER#j9}Qc+M(PEAZpN=ZmZMnyzJLP0=3K0Q1;IypEu
      zHZ?ReGBGeOE-fr8Dk&%@CM6^zA|W6j9vvJT8W|WD78Mi|5)lv&4h;+o3JC}Y1_cBI
      G0s#P8`+tD|

      literal 256
      zcmV+b0ssC00RjUA1qKHQ2?`4g4Gs?w5fT#=6&4p585$cL9UdPbAtECrB_<~*DJm;0
      zEiNxGF)}kWH8wXmIXXK$Jw87`K|(`BMMg(RNlHshO-@fxQBqS>RaRG6Sz23MU0z>c
      zVPa!sWoBn+X=-b1ZEkOHadLBXb#`}nd3t+%eSUv{fr5jCg@%WSiHeJijgF6yk&=^?
      zm6n&7nVOrNot~edp`xRtrKYE-sj922t*)=Iv9hzYwYImoxw^Z&y}rM|!NSAD#m2|T
      z$;!*j&Cbuz(bCh@)z;V8+1lIO-QM5e;o{@u<>u$;>FVq3?e6dJ@$&QZ_4fDp`TG0(
      G{r>;0_J4r@
    PATCH

    BINARY_ADD_PATCH = <<~PATCH
      diff --git a/image.bin b/image.bin
      new file mode 100644
      index 0000000000000000000000000000000000000000..96eb299ab61d459148b19b03f71386abcec74669
      GIT binary patch
      literal 64
      zcmZQzWMXDvWn<^y<l^Sx<>MC+6cQE@6%&_`l#-T_m6KOcR8m$^Ra4i{)Y8_`)zddH
      TG%_|ZH8Z!cw6eCbwX+8Rs^ACV

      literal 0
      HcmV?d00001
    PATCH

    BINARY_DELETE_PATCH = <<~PATCH
      diff --git a/image.bin b/image.bin
      deleted file mode 100644
      index 96eb299ab61d459148b19b03f71386abcec74669..0000000000000000000000000000000000000000
      GIT binary patch
      literal 0
      HcmV?d00001

      literal 64
      zcmZQzWMXDvWn<^y<l^Sx<>MC+6cQE@6%&_`l#-T_m6KOcR8m$^Ra4i{)Y8_`)zddH
      TG%_|ZH8Z!cw6eCbwX+8Rs^ACV
    PATCH

    BINARY_RENAME_CHANGE_PATCH = <<~PATCH
      diff --git a/lib/old.bin b/lib/new.bin
      similarity index 95%
      rename from lib/old.bin
      rename to lib/new.bin
      index c86626638e0bc8cf47ca49bb1525b40e9737ee64..0aaa0f198cef816245eb1dc21ce8b1ffe2e61584 100644
      GIT binary patch
      delta 9
      QcmZo*YG7hyoXGee01Dy)m;e9(

      delta 9
      QcmZo*YG7hyn8^4a01Dm$mjD0&
    PATCH

    def source_for(text = SAMPLE_PATCH)
      PatchUtil::Source.from_diff_text(text, label: 'spec.diff')
    end

    def parsed_diff(text = SAMPLE_PATCH)
      PatchUtil::Parser.new.parse(source_for(text))
    end

    def capture_stdout
      original_stdout = $stdout
      buffer = StringIO.new
      $stdout = buffer
      yield
      buffer.string
    ensure
      $stdout = original_stdout
    end

    def create_git_repo_with_patch(patch_text = SAMPLE_PATCH)
      Dir.mktmpdir do |dir|
        run_git(dir, %w[init])
        File.write(File.join(dir, 'example.rb'), sample_old_text(patch_text))
        run_git(dir, %w[add example.rb])
        run_git(dir, %w[commit -m base], env: git_env)
        File.write(File.join(dir, 'example.rb'), sample_new_text(patch_text))
        run_git(dir, %w[commit -am change], env: git_env)
        yield dir
      end
    end

    def create_linear_git_repo_for_rewrite
      Dir.mktmpdir do |dir|
        run_git(dir, %w[init])
        file_path = File.join(dir, 'example.rb')

        File.write(file_path, sample_old_text(SAMPLE_PATCH))
        run_git(dir, %w[add example.rb])
        run_git(dir, %w[commit -m base], env: git_env)
        base_sha = run_git(dir, %w[rev-parse HEAD]).strip

        File.write(file_path, sample_new_text(SAMPLE_PATCH))
        run_git(dir, %w[commit -am change], env: git_env)
        change_sha = run_git(dir, %w[rev-parse HEAD]).strip

        File.write(file_path, [
          'function a() {',
          '  var b;',
          '  do_something_else();',
          '  return true;',
          '}',
          '',
          'function c() {',
          '  return false;',
          '}'
        ].join("\n") + "\n")
        run_git(dir, %w[commit -am follow-up], env: git_env)
        follow_up_sha = run_git(dir, %w[rev-parse HEAD]).strip

        yield dir, { base: base_sha, change: change_sha, follow_up: follow_up_sha }
      end
    end

    def create_linear_git_repo_for_rewrite_with_trailers
      Dir.mktmpdir do |dir|
        run_git(dir, %w[init])
        file_path = File.join(dir, 'example.rb')

        File.write(file_path, sample_old_text(SAMPLE_PATCH))
        run_git(dir, %w[add example.rb])
        run_git(dir, %w[commit -m base], env: git_env)
        base_sha = run_git(dir, %w[rev-parse HEAD]).strip

        File.write(file_path, sample_new_text(SAMPLE_PATCH))
        trailer_message = [
          'change',
          '',
          'Detailed body for change.',
          '',
          'Co-authored-by: Pair Person <pair@example.com>',
          'Tested-by: Test Runner <test@example.com>',
          'Signed-off-by: Patch Util Spec <patch-util-spec@example.com>'
        ].join("\n")
        run_git(dir, ['commit', '-am', trailer_message], env: git_env)
        change_sha = run_git(dir, %w[rev-parse HEAD]).strip

        File.write(file_path, [
          'function a() {',
          '  var b;',
          '  do_something_else();',
          '  return true;',
          '}',
          '',
          'function c() {',
          '  return false;',
          '}'
        ].join("\n") + "\n")
        run_git(dir, %w[commit -am follow-up], env: git_env)
        follow_up_sha = run_git(dir, %w[rev-parse HEAD]).strip

        yield dir, { base: base_sha, change: change_sha, follow_up: follow_up_sha }
      end
    end

    def create_linear_git_repo_for_rewrite_with_metadata
      Dir.mktmpdir do |dir|
        run_git(dir, %w[init])
        file_path = File.join(dir, 'example.rb')

        File.write(file_path, sample_old_text(SAMPLE_PATCH))
        run_git(dir, %w[add example.rb])
        run_git(dir, %w[commit -m base], env: git_env)
        base_sha = run_git(dir, %w[rev-parse HEAD]).strip

        File.write(file_path, sample_new_text(SAMPLE_PATCH))
        metadata_message = [
          'change',
          '',
          'Detailed body for change.',
          '',
          'Co-authored-by: Pair Person <pair@example.com>',
          'Tested-by: Test Runner <test@example.com>',
          'Signed-off-by: Patch Util Spec <patch-util-spec@example.com>'
        ].join("\n")
        metadata_env = git_env.merge(
          'GIT_AUTHOR_NAME' => 'Original Author',
          'GIT_AUTHOR_EMAIL' => 'author@example.com',
          'GIT_AUTHOR_DATE' => '2026-03-17T05:00:00+00:00',
          'GIT_COMMITTER_NAME' => 'Original Committer',
          'GIT_COMMITTER_EMAIL' => 'committer@example.com',
          'GIT_COMMITTER_DATE' => '2026-03-17T06:00:00+00:00'
        )
        run_git(dir, ['commit', '-am', metadata_message], env: metadata_env)
        change_sha = run_git(dir, %w[rev-parse HEAD]).strip

        File.write(file_path, [
          'function a() {',
          '  var b;',
          '  do_something_else();',
          '  return true;',
          '}',
          '',
          'function c() {',
          '  return false;',
          '}'
        ].join("\n") + "\n")
        run_git(dir, %w[commit -am follow-up], env: git_env)
        follow_up_sha = run_git(dir, %w[rev-parse HEAD]).strip

        yield dir, { base: base_sha, change: change_sha, follow_up: follow_up_sha }
      end
    end

    def create_linear_git_repo_with_new_file_rewrite
      Dir.mktmpdir do |dir|
        run_git(dir, %w[init])
        existing_path = File.join(dir, 'existing.rb')
        added_dir = File.join(dir, 'lib')
        added_path = File.join(added_dir, 'new_file.rb')

        File.write(existing_path, "old line\nsame line\n")
        run_git(dir, %w[add existing.rb])
        run_git(dir, %w[commit -m base], env: git_env)
        base_sha = run_git(dir, %w[rev-parse HEAD]).strip

        File.write(existing_path, "new line\nsame line\n")
        FileUtils.mkdir_p(added_dir)
        File.write(added_path, "alpha\nbeta\n")
        run_git(dir, %w[add existing.rb lib/new_file.rb])
        run_git(dir, %w[commit -m mixed-change], env: git_env)
        change_sha = run_git(dir, %w[rev-parse HEAD]).strip

        File.write(existing_path, "new line\nsame line\ntrailer\n")
        run_git(dir, %w[add existing.rb])
        run_git(dir, %w[commit -m follow-up], env: git_env)
        follow_up_sha = run_git(dir, %w[rev-parse HEAD]).strip

        yield dir, { base: base_sha, change: change_sha, follow_up: follow_up_sha }
      end
    end

    def create_git_repo_with_merge_commit
      Dir.mktmpdir do |dir|
        run_git(dir, %w[init])
        example_path = File.join(dir, 'example.rb')
        extra_path = File.join(dir, 'feature.txt')

        File.write(example_path, "base\n")
        run_git(dir, %w[add example.rb])
        run_git(dir, %w[commit -m base], env: git_env)

        run_git(dir, %w[checkout -b feature], env: git_env)
        File.write(extra_path, "feature\n")
        run_git(dir, %w[add feature.txt])
        run_git(dir, %w[commit -m feature], env: git_env)
        feature_sha = run_git(dir, %w[rev-parse HEAD]).strip

        run_git(dir, %w[checkout master], env: git_env)
        File.write(example_path, "base\nmain\n")
        run_git(dir, %w[commit -am main], env: git_env)
        main_sha = run_git(dir, %w[rev-parse HEAD]).strip

        run_git(dir, %w[merge feature -m merge-feature], env: git_env)
        merge_sha = run_git(dir, %w[rev-parse HEAD]).strip

        yield dir, { main: main_sha, feature: feature_sha, merge: merge_sha }
      end
    end

    def create_git_repo_with_binary_commit
      Dir.mktmpdir do |dir|
        run_git(dir, %w[init])
        binary_path = File.join(dir, 'image.bin')

        File.binwrite(binary_path, "\x00" * 64)
        run_git(dir, %w[add image.bin])
        run_git(dir, %w[commit -m base-binary], env: git_env)

        File.binwrite(binary_path, (0...64).map { |index| (index * 3) % 256 }.pack('C*'))
        run_git(dir, %w[add image.bin])
        run_git(dir, %w[commit -m binary-change], env: git_env)
        change_sha = run_git(dir, %w[rev-parse HEAD]).strip

        yield dir, { change: change_sha }
      end
    end

    def create_git_repo_with_binary_add_and_delete_commits
      Dir.mktmpdir do |dir|
        run_git(dir, %w[init])
        marker_path = File.join(dir, 'README.txt')
        binary_path = File.join(dir, 'image.bin')

        File.write(marker_path, "base\n")
        run_git(dir, %w[add README.txt])
        run_git(dir, %w[commit -m base], env: git_env)
        base_sha = run_git(dir, %w[rev-parse HEAD]).strip

        File.binwrite(binary_path, (0...64).map { |index| (index * 5) % 256 }.pack('C*'))
        run_git(dir, %w[add image.bin])
        run_git(dir, %w[commit -m add-binary], env: git_env)
        add_sha = run_git(dir, %w[rev-parse HEAD]).strip

        File.delete(binary_path)
        run_git(dir, %w[add -u image.bin])
        run_git(dir, %w[commit -m delete-binary], env: git_env)
        delete_sha = run_git(dir, %w[rev-parse HEAD]).strip

        yield dir, { base: base_sha, add: add_sha, delete: delete_sha }
      end
    end

    def create_git_repo_with_binary_rename_change_commit
      Dir.mktmpdir do |dir|
        run_git(dir, %w[init])
        old_path = File.join(dir, 'old.bin')
        new_path = File.join(dir, 'new.bin')

        File.binwrite(old_path, (0...64).map { |index| (index * 5) % 256 }.pack('C*'))
        run_git(dir, %w[add old.bin])
        run_git(dir, %w[commit -m base], env: git_env)
        base_sha = run_git(dir, %w[rev-parse HEAD]).strip

        run_git(dir, %w[mv old.bin new.bin])
        bytes = File.binread(new_path).bytes
        bytes[0] = (bytes[0] + 1) % 256
        File.binwrite(new_path, bytes.pack('C*'))
        run_git(dir, %w[add -A])
        run_git(dir, %w[commit -m rename-binary], env: git_env)
        change_sha = run_git(dir, %w[rev-parse HEAD]).strip

        yield dir, { base: base_sha, change: change_sha }
      end
    end

    def create_linear_git_repo_with_binary_rewrite
      Dir.mktmpdir do |dir|
        run_git(dir, %w[init])
        binary_path = File.join(dir, 'image.bin')
        notes_path = File.join(dir, 'notes.txt')

        File.binwrite(binary_path, "\x00" * 64)
        File.write(notes_path, "base\n")
        run_git(dir, %w[add image.bin notes.txt])
        run_git(dir, %w[commit -m base], env: git_env)
        base_sha = run_git(dir, %w[rev-parse HEAD]).strip

        changed_binary = (0...64).map { |index| (index * 7) % 256 }.pack('C*')
        File.binwrite(binary_path, changed_binary)
        run_git(dir, %w[add image.bin])
        run_git(dir, %w[commit -m binary-change], env: git_env)
        change_sha = run_git(dir, %w[rev-parse HEAD]).strip

        File.write(notes_path, "base\nfollow-up\n")
        run_git(dir, %w[add notes.txt])
        run_git(dir, %w[commit -m follow-up], env: git_env)
        follow_up_sha = run_git(dir, %w[rev-parse HEAD]).strip

        yield dir, { base: base_sha, change: change_sha, follow_up: follow_up_sha, binary_bytes: changed_binary }
      end
    end

    def create_git_repo_with_earlier_commit_and_merge_descendant
      Dir.mktmpdir do |dir|
        run_git(dir, %w[init])
        main_path = File.join(dir, 'example.rb')
        branch_path = File.join(dir, 'feature.txt')

        File.write(main_path, "base\n")
        run_git(dir, %w[add example.rb])
        run_git(dir, %w[commit -m base], env: git_env)
        base_sha = run_git(dir, %w[rev-parse HEAD]).strip

        File.write(main_path, "base\nchange one\nchange two\n")
        run_git(dir, %w[commit -am target-change], env: git_env)
        target_sha = run_git(dir, %w[rev-parse HEAD]).strip

        run_git(dir, %w[checkout -b feature], env: git_env)
        File.write(branch_path, "feature side\n")
        run_git(dir, %w[add feature.txt])
        run_git(dir, %w[commit -m feature-side], env: git_env)
        feature_sha = run_git(dir, %w[rev-parse HEAD]).strip

        run_git(dir, %w[checkout master], env: git_env)
        File.write(main_path, "base\nchange one\nchange two\nfollow up\n")
        run_git(dir, %w[commit -am follow-up], env: git_env)
        follow_up_sha = run_git(dir, %w[rev-parse HEAD]).strip

        run_git(dir, %w[merge feature -m merge-feature], env: git_env)
        merge_sha = run_git(dir, %w[rev-parse HEAD]).strip

        yield dir, { base: base_sha, target: target_sha, feature: feature_sha, follow_up: follow_up_sha,
                     merge: merge_sha }
      end
    end

    def write_retained_state(git_dir:, branch:, target_sha:, head_sha:, worktree_path:, backup_ref:,
                             pending_revisions: ['deadbeef'], message: 'simulated retained state')
      store = PatchUtil::Git::RewriteStateStore.new(git_dir: git_dir)
      store.record_failure(
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
      )
    end

    def run_git(dir, args, env: {})
      stdout, stderr, status = Open3.capture3(env, 'git', '-C', dir, *args)
      raise "git failed: #{args.join(' ')}\n#{stdout}\n#{stderr}" unless status.success?

      stdout
    end

    def git_env
      {
        'GIT_AUTHOR_NAME' => 'Patch Util Spec',
        'GIT_AUTHOR_EMAIL' => 'patch-util-spec@example.com',
        'GIT_COMMITTER_NAME' => 'Patch Util Spec',
        'GIT_COMMITTER_EMAIL' => 'patch-util-spec@example.com'
      }
    end

    def sample_old_text(patch_text)
      case patch_text
      when SAMPLE_PATCH
        [
          'function a() {',
          '  var b;',
          '  do_something();',
          '  return true;',
          '}'
        ].join("\n") + "\n"
      when OFFSET_PATCH
        [
          'function a() {',
          '  do_something();',
          '  return true;',
          '}',
          '',
          '',
          '',
          '',
          '',
          'function b() {',
          '  return false;',
          '}'
        ].join("\n") + "\n"
      else
        raise 'unknown sample patch'
      end
    end

    def sample_new_text(patch_text)
      case patch_text
      when SAMPLE_PATCH
        [
          'function a() {',
          '  var b;',
          '  do_something_else();',
          '  return true;',
          '}'
        ].join("\n") + "\n"
      when OFFSET_PATCH
        [
          'function a() {',
          '  return true;',
          '}',
          '',
          '',
          '',
          '',
          '',
          'function b() {',
          '  do_other();',
          '  return false;',
          '}'
        ].join("\n") + "\n"
      else
        raise 'unknown sample patch'
      end
    end
  end
end

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_status'
  config.include PatchUtil::SpecHelpers

  config.expect_with :rspec do |expectations|
    expectations.syntax = :should
  end

  config.mock_with :rspec do |mocks|
    mocks.syntax = %i[should expect]
  end
end
