# frozen_string_literal: true

require 'thor'

module PatchUtil
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    desc 'version', 'Display PatchUtil version'
    def version
      puts PatchUtil::VERSION
    end

    desc 'rewrite SUBCOMMAND ...ARGS', 'Manage retained git rewrite sessions'
    subcommand 'rewrite', PatchUtil::Git::RewriteCLI

    desc 'split SUBCOMMAND ...ARGS', 'Inspect, plan, and emit split patches'
    subcommand 'split', PatchUtil::Split::CLI
  end
end
