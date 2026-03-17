# frozen_string_literal: true

require 'digest'

module PatchUtil
  class Source
    attr_reader :diff_text, :fingerprint, :kind, :label, :path, :repo_path, :commit_sha, :parent_shas

    def self.from_diff_text(diff_text, label: 'stdin')
      bytes = diff_text.dup.force_encoding(Encoding::BINARY)
      new(
        kind: 'raw_diff',
        label: label,
        path: nil,
        diff_text: bytes.dup.force_encoding(Encoding::UTF_8),
        fingerprint: Digest::SHA256.hexdigest(bytes)
      )
    end

    def self.from_patch_file(path)
      expanded = File.expand_path(path)
      bytes = File.binread(expanded)
      new(
        kind: 'patch_file',
        label: path,
        path: expanded,
        diff_text: bytes.dup.force_encoding(Encoding::UTF_8),
        fingerprint: Digest::SHA256.hexdigest(bytes)
      )
    end

    def self.from_git_commit(repo_path:, revision: 'HEAD', git_cli: PatchUtil::Git::Cli.new)
      root = git_cli.repo_root(repo_path)
      sha = git_cli.rev_parse(root, revision)
      parent_shas = git_cli.parent_shas(root, sha)
      if parent_shas.length > 1
        raise ValidationError,
              "merge commits are not supported yet for inspect/plan/apply: #{sha} has #{parent_shas.length} parents"
      end

      diff_text = git_cli.show_commit_patch(root, sha)
      new(
        kind: 'git_commit',
        label: "#{root}@#{sha}",
        path: nil,
        diff_text: diff_text,
        fingerprint: sha,
        repo_path: root,
        commit_sha: sha,
        parent_shas: parent_shas
      )
    end

    def initialize(kind:, label:, path:, diff_text:, fingerprint:, repo_path: nil, commit_sha: nil, parent_shas: [])
      @kind = kind
      @label = label
      @path = path
      @diff_text = diff_text
      @fingerprint = fingerprint
      @repo_path = repo_path
      @commit_sha = commit_sha
      @parent_shas = parent_shas
    end

    def git?
      kind.start_with?('git_')
    end
  end
end
