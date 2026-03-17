# frozen_string_literal: true

module PatchUtil
  autoload :VERSION, 'patch_util/version'
  class Error < StandardError; end
  class ParseError < Error; end
  class ValidationError < Error; end
  class UnsupportedFeatureError < Error; end

  autoload :Git, 'patch_util/git'
  autoload :Source, 'patch_util/source'
  autoload :Diff, 'patch_util/diff'
  autoload :FileDiff, 'patch_util/diff'
  autoload :Hunk, 'patch_util/diff'
  autoload :Row, 'patch_util/diff'
  autoload :ChangeLine, 'patch_util/diff'
  autoload :Parser, 'patch_util/parser'
  autoload :Selection, 'patch_util/selection'
  autoload :Split, 'patch_util/split'
  autoload :CLI, 'patch_util/cli'
end
