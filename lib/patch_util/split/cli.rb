# frozen_string_literal: true

require 'fileutils'
require 'thor'

module PatchUtil
  module Split
    class CLI < Thor
      desc 'inspect', 'Display annotated diff lines and any saved plan overlay'
      option :patch, type: :string, aliases: '-p', banner: 'PATH'
      option :commit, type: :string, aliases: '-c', banner: 'REV'
      option :repo, type: :string, aliases: '-r', banner: 'PATH'
      option :plan, type: :string, aliases: '-P', banner: 'PATH'
      option :compact, type: :boolean, default: false, banner: 'BOOL'
      option :expand, type: :string, banner: 'HUNKS'
      def inspect
        source = load_source
        diff = PatchUtil::Parser.new.parse(source)
        plan_entry = load_plan_entry(source)
        expand_hunks = parse_expanded_hunks(diff)
        puts Inspector.new.render(diff: diff,
                                  plan_entry: plan_entry,
                                  compact: options[:compact],
                                  expand_hunks: expand_hunks)
      end

      desc 'plan [NAME SELECTORS]... [LEFTOVERS_NAME]', 'Persist a split plan'
      option :patch, type: :string, aliases: '-p', banner: 'PATH'
      option :commit, type: :string, aliases: '-c', banner: 'REV'
      option :repo, type: :string, aliases: '-r', banner: 'PATH'
      option :plan, type: :string, aliases: '-P', banner: 'PATH'
      def plan(*args)
        source = load_source
        diff = PatchUtil::Parser.new.parse(source)
        chunk_requests = build_chunk_requests(args)
        plan_entry = Planner.new.build(source: source, diff: diff, chunk_requests: chunk_requests)

        store = PlanStore.new(path: resolve_plan_path(source))
        plan_set = store.upsert(store.load, plan_entry)
        store.save(plan_set)

        puts "saved #{plan_entry.chunks.length} chunks to #{store.path}"
      end

      desc 'apply', 'Emit one patch file per saved chunk'
      option :patch, type: :string, aliases: '-p', banner: 'PATH'
      option :commit, type: :string, aliases: '-c', banner: 'REV'
      option :repo, type: :string, aliases: '-r', banner: 'PATH'
      option :plan, type: :string, aliases: '-P', banner: 'PATH'
      option :output_dir, type: :string, aliases: '-o', banner: 'DIR'
      option :rewrite, type: :boolean, default: false, banner: 'BOOL'
      def apply
        source = load_source
        diff = PatchUtil::Parser.new.parse(source)
        plan_entry = load_plan_entry(source)
        raise ValidationError, "no saved plan matches #{source.label}" unless plan_entry

        if options[:rewrite]
          raise ValidationError, '--rewrite is only supported for git commit sources' unless source.git?

          result = PatchUtil::Git::Rewriter.new.rewrite(source: source, diff: diff, plan_entry: plan_entry)
          puts "rewrote #{result.branch}: #{result.old_head} -> #{result.new_head}"
          puts "backup ref: #{result.backup_ref}"
          result.commits.each { |name| puts "created #{name}" }
        else
          raise ValidationError, '--output-dir is required unless --rewrite is used' unless options[:output_dir]

          emitted = Applier.new.apply(diff: diff, plan_entry: plan_entry, output_dir: options[:output_dir])
          emitted.each do |item|
            puts "#{item[:name]} -> #{item[:path]}"
          end
        end
      end

      no_commands do
        def load_source
          validate_source_options!

          if options[:patch]
            PatchUtil::Source.from_patch_file(options[:patch])
          else
            PatchUtil::Source.from_git_commit(repo_path: options[:repo] || Dir.pwd,
                                              revision: options[:commit] || 'HEAD')
          end
        end

        def build_chunk_requests(args)
          raise ValidationError, 'plan requires at least one chunk name and selector' if args.empty?

          requests = []
          pairable_count = args.length.even? ? args.length : args.length - 1
          index = 0

          while index < pairable_count
            name = args[index]
            selector_text = args[index + 1]
            raise ValidationError, "missing selector for chunk #{name}" if selector_text.nil?

            requests << ChunkRequest.new(name: name, selector_text: selector_text, leftovers: false)
            index += 2
          end

          requests << ChunkRequest.new(name: args[-1], selector_text: nil, leftovers: true) if args.length.odd?

          requests
        end

        def parse_expanded_hunks(diff)
          selector_text = options[:expand]
          return [] unless selector_text

          raise ValidationError, '--expand requires --compact' unless options[:compact]

          selectors = PatchUtil::Selection::Parser.new.parse(selector_text)
          raise ValidationError, '--expand requires at least one hunk label' if selectors.empty?

          labels = []
          selectors.each do |selector|
            unless selector.whole_hunk?
              raise ValidationError,
                    '--expand only accepts whole-hunk labels or hunk ranges (for example: a,b,c or a-c)'
            end

            unless diff.hunk_by_label(selector.hunk_label)
              raise ValidationError,
                    "unknown hunk label for --expand: #{selector.hunk_label}"
            end

            labels << selector.hunk_label
          end

          labels.uniq
        end

        def load_plan_entry(source)
          store = PlanStore.new(path: resolve_plan_path(source))
          store.load.find_entry(source)
        end

        def resolve_plan_path(source)
          return File.expand_path(options[:plan]) if options[:plan]

          if source.git?
            git_dir = PatchUtil::Git::Cli.new.git_dir(source.repo_path)
            return File.join(git_dir, 'patch_util', 'plans.json')
          end

          raise ValidationError, "--plan is required for #{source.kind} sources outside a git repository"
        end

        def validate_source_options!
          if options[:patch] && (options[:commit] || options[:repo])
            raise ValidationError, 'use either --patch or --commit/--repo source options, not both'
          end

          raise ValidationError, '--repo requires --commit when used explicitly' if options[:repo] && !options[:commit]

          return if options[:patch]
          return if options[:commit]
          return if PatchUtil::Git::Cli.new.inside_repo?(options[:repo] || Dir.pwd)

          raise ValidationError, 'provide --patch, or run inside a git repository, or pass --commit with --repo'
        end
      end
    end
  end
end
