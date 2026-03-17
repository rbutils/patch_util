# frozen_string_literal: true

module PatchUtil
  module Git
    autoload :Cli, 'patch_util/git/cli'
    autoload :RewriteStateStore, 'patch_util/git/rewrite_state_store'
    autoload :RewriteSessionManager, 'patch_util/git/rewrite_session_manager'
    autoload :Rewriter, 'patch_util/git/rewriter'
    autoload :RewriteCLI, 'patch_util/git/rewrite_cli'
  end
end
