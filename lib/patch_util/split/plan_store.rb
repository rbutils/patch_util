# frozen_string_literal: true

require 'fileutils'
require 'json'

module PatchUtil
  module Split
    class PlanStore
      FORMAT_VERSION = 1

      attr_reader :path

      def initialize(path:)
        @path = File.expand_path(path)
      end

      def load
        return PlanSet.new(version: FORMAT_VERSION, entries: []) unless File.exist?(path)

        payload = JSON.parse(File.read(path))
        entries = []
        payload.fetch('entries', []).each do |entry|
          entries << deserialize_entry(entry)
        end
        PlanSet.new(version: payload.fetch('version', FORMAT_VERSION), entries: entries)
      end

      def save(plan_set)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate(serialize_plan_set(plan_set)) + "\n")
      end

      def upsert(plan_set, entry)
        entries = []
        replaced = false

        plan_set.entries.each do |existing|
          if existing.source_kind == entry.source_kind && existing.source_fingerprint == entry.source_fingerprint
            entries << entry
            replaced = true
          else
            entries << existing
          end
        end

        entries << entry unless replaced
        PlanSet.new(version: FORMAT_VERSION, entries: entries)
      end

      private

      def serialize_plan_set(plan_set)
        entries = []
        plan_set.entries.each do |entry|
          entries << {
            'source_kind' => entry.source_kind,
            'source_label' => entry.source_label,
            'source_fingerprint' => entry.source_fingerprint,
            'created_at' => entry.created_at,
            'chunks' => serialize_chunks(entry.chunks)
          }
        end

        {
          'version' => plan_set.version,
          'entries' => entries
        }
      end

      def serialize_chunks(chunks)
        items = []
        chunks.each do |chunk|
          items << {
            'name' => chunk.name,
            'selector_text' => chunk.selector_text,
            'row_ids' => chunk.row_ids,
            'change_labels' => chunk.change_labels,
            'leftovers' => chunk.leftovers?
          }
        end
        items
      end

      def deserialize_entry(entry)
        chunks = []
        entry.fetch('chunks', []).each do |chunk|
          chunks << Chunk.new(
            name: chunk.fetch('name'),
            selector_text: chunk['selector_text'],
            row_ids: chunk.fetch('row_ids'),
            change_labels: chunk.fetch('change_labels'),
            leftovers: chunk.fetch('leftovers', false)
          )
        end

        PlanEntry.new(
          source_kind: entry.fetch('source_kind'),
          source_label: entry.fetch('source_label'),
          source_fingerprint: entry.fetch('source_fingerprint'),
          chunks: chunks,
          created_at: entry.fetch('created_at')
        )
      end
    end
  end
end
