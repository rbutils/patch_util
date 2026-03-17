# frozen_string_literal: true

require 'fileutils'

module PatchUtil
  module Split
    class Applier
      def initialize(emitter: Emitter.new)
        @emitter = emitter
      end

      def apply(diff:, plan_entry:, output_dir:)
        projector = Projector.new(diff: diff, plan_entry: plan_entry)
        target_dir = File.expand_path(output_dir)
        FileUtils.mkdir_p(target_dir)

        emitted = []
        plan_entry.chunks.each_with_index do |chunk, chunk_index|
          patch_text = @emitter.emit(projector.project_chunk(chunk_index))
          raise ValidationError, "chunk #{chunk.name} did not produce a patch" if patch_text.empty?

          path = File.join(target_dir, format('%04d-%s.patch', chunk_index + 1, slug(chunk.name)))
          File.write(path, patch_text)
          emitted << { name: chunk.name, path: path, patch_text: patch_text }
        end

        emitted
      end

      private

      def slug(name)
        normalized = name.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-|-\z/, '')
        normalized.empty? ? 'chunk' : normalized
      end
    end
  end
end
