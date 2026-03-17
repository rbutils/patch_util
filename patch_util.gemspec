# frozen_string_literal: true

require_relative 'lib/patch_util/version'

Gem::Specification.new do |spec|
  spec.name = 'patch_util'
  spec.version = PatchUtil::VERSION
  spec.authors = ['hmdne']
  spec.email = ['54514036+hmdne@users.noreply.github.com']

  spec.summary = 'Split unified diffs into smaller ordered patches'
  spec.description = 'Patch planning and materialization helpers for splitting one unified diff into multiple reviewable patches.'
  spec.homepage = 'https://github.com/rbutils/patch_util'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.2.0'

  spec.metadata['allowed_push_host'] = 'https://rubygems.org'
  spec.metadata['source_code_uri'] = 'https://github.com/rbutils/patch_util'
  spec.metadata['changelog_uri'] = 'https://github.com/rbutils/patch_util/blob/master/CHANGELOG.md'
  spec.metadata['documentation_uri'] = 'https://github.com/rbutils/patch_util#readme'
  spec.metadata['bug_tracker_uri'] = 'https://github.com/rbutils/patch_util/issues'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = if File.directory?(File.join(__dir__, '.git'))
                 gemspec = File.basename(__FILE__)
                 IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
                   ls.readlines("\x0", chomp: true).reject do |path|
                     (path == gemspec) ||
                       path.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
                   end
                 end
               else
                 Dir.chdir(__dir__) do
                   paths = []
                   ['CHANGELOG.md', 'LICENSE.txt', 'README.md', 'SKILL.md', '.rspec'].each do |path|
                     paths << path if File.file?(path)
                   end
                   Dir.glob('exe/*').each { |path| paths << path if File.file?(path) }
                   Dir.glob('lib/**/*.rb').each { |path| paths << path if File.file?(path) }
                   paths
                 end
               end
  spec.bindir = 'exe'
  spec.executables = ['patch_util']
  spec.require_paths = ['lib']

  spec.add_dependency 'thor', '~> 1.2'
end
