# frozen_string_literal: true

module PatchUtil
  module Split
    autoload :Plan, 'patch_util/split/plan'
    autoload :ChunkRequest, 'patch_util/split/plan'
    autoload :Chunk, 'patch_util/split/plan'
    autoload :PlanEntry, 'patch_util/split/plan'
    autoload :PlanSet, 'patch_util/split/plan'
    autoload :PlanStore, 'patch_util/split/plan_store'
    autoload :Verifier, 'patch_util/split/verifier'
    autoload :Planner, 'patch_util/split/planner'
    autoload :ProjectedFile, 'patch_util/split/projector'
    autoload :ProjectedHunk, 'patch_util/split/projector'
    autoload :Projector, 'patch_util/split/projector'
    autoload :Emitter, 'patch_util/split/emitter'
    autoload :Applier, 'patch_util/split/applier'
    autoload :Inspector, 'patch_util/split/inspector'
    autoload :CLI, 'patch_util/split/cli'
  end
end
