# frozen_string_literal: true

require 'fileutils'
require 'json'

module PatchUtil
  module Git
    class RewriteStateStore
      State = Data.define(:branch, :target_sha, :head_sha, :backup_ref, :worktree_path, :status, :message, :created_at,
                          :pending_revisions)

      def initialize(git_dir:)
        @git_dir = File.expand_path(git_dir)
      end

      def path
        File.join(@git_dir, 'patch_util', 'rewrite_state.json')
      end

      def load
        return [] unless File.exist?(path)

        payload = JSON.parse(File.read(path))
        payload.fetch('states', []).map do |item|
          State.new(
            branch: item.fetch('branch'),
            target_sha: item.fetch('target_sha'),
            head_sha: item.fetch('head_sha'),
            backup_ref: item.fetch('backup_ref'),
            worktree_path: item.fetch('worktree_path'),
            status: item.fetch('status'),
            message: item.fetch('message'),
            created_at: item.fetch('created_at'),
            pending_revisions: item.fetch('pending_revisions', [])
          )
        end
      end

      def record_failure(state)
        states = load.reject { |item| item.branch == state.branch }
        states << state
        save(states)
      end

      def clear_branch(branch)
        states = load.reject { |item| item.branch == branch }
        save(states)
      end

      def find_branch(branch)
        load.find { |state| state.branch == branch }
      end

      private

      def save(states)
        if states.empty?
          FileUtils.rm_f(path)
          return
        end

        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate('states' => states.map { |state| serialize(state) }) + "\n")
      end

      def serialize(state)
        {
          'branch' => state.branch,
          'target_sha' => state.target_sha,
          'head_sha' => state.head_sha,
          'backup_ref' => state.backup_ref,
          'worktree_path' => state.worktree_path,
          'status' => state.status,
          'message' => state.message,
          'created_at' => state.created_at,
          'pending_revisions' => state.pending_revisions
        }
      end
    end
  end
end
