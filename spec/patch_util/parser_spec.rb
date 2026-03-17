# frozen_string_literal: true

RSpec.describe PatchUtil::Parser do
  subject(:diff) { described_class.new.parse(source_for) }

  it 'assigns hunk and changed-line labels for inspection' do
    diff.hunks.map(&:label).should
    diff.hunks.first.change_lines.map(&:label).should

    rendered = PatchUtil::Split::Inspector.new.render(diff: diff)
    rendered.should include('a1')
    rendered.should include('a2')
    rendered.should include('-  do_something();')
    rendered.should include('+  do_something_else();')
  end

  it 'parses rename metadata as a regular operation hunk ahead of text hunks' do
    diff = described_class.new.parse(source_for(PatchUtil::SpecHelpers::RENAME_PATCH))

    diff.hunks.map(&:label).should
    diff.hunks.first.operation?.should
    diff.hunks.first.change_lines.map(&:label).should
    diff.hunks.first.change_lines.first.text.should
    diff.hunks.last.change_lines.map(&:label).should

    rendered = PatchUtil::Split::Inspector.new.render(diff: diff)
    rendered.should include('a1')
    rendered.should include('=rename lib/old.rb -> lib/new.rb (71%)')
    rendered.should include('b1')
    rendered.should include('b2')
  end

  it 'parses metadata-only renames as operation-only diffs' do
    diff = described_class.new.parse(source_for(PatchUtil::SpecHelpers::RENAME_ONLY_PATCH))

    diff.hunks.map(&:label).should
    diff.hunks.first.operation?.should
    diff.hunks.first.change_lines.map(&:label).should
    diff.file_diffs.first.rename?.should == true
  end

  it 'parses copy metadata as a regular operation hunk' do
    diff = described_class.new.parse(source_for(PatchUtil::SpecHelpers::COPY_PATCH))

    diff.hunks.map(&:label).should
    diff.hunks.first.operation?.should
    diff.hunks.first.change_lines.first.text.should
    diff.file_diffs.first.copy?.should == true
  end

  it 'parses mode-only metadata as an operation hunk' do
    diff = described_class.new.parse(source_for(PatchUtil::SpecHelpers::MODE_PATCH))

    diff.hunks.map(&:label).should
    diff.hunks.first.operation?.should
    diff.hunks.first.change_lines.map(&:label).should
    diff.hunks.first.change_lines.first.text.should

    rendered = PatchUtil::Split::Inspector.new.render(diff: diff)
    rendered.should include('a1')
    rendered.should include('=mode bin/tool 100644 -> 100755')
  end

  it 'parses combined rename and mode metadata into one operation hunk' do
    diff = described_class.new.parse(source_for(PatchUtil::SpecHelpers::RENAME_WITH_MODE_PATCH))

    diff.hunks.map(&:label).should
    diff.hunks.first.operation?.should
    diff.hunks.first.change_lines.first.text.should == 'rename lib/old.rb -> lib/new.rb (71%), mode lib/new.rb 100644 -> 100755'
  end

  it 'parses binary modification payloads as regular selectable hunks' do
    diff = described_class.new.parse(source_for(PatchUtil::SpecHelpers::BINARY_PATCH))

    diff.hunks.map(&:label).should
    diff.hunks.first.binary?.should
    diff.hunks.first.change_lines.map(&:label).should
    diff.hunks.first.change_lines.first.text.should

    rendered = PatchUtil::Split::Inspector.new.render(diff: diff)
    rendered.should include('a1')
    rendered.should include('=binary image.bin')
  end

  it 'parses binary add and delete payloads as binary hunks' do
    add_diff = described_class.new.parse(source_for(PatchUtil::SpecHelpers::BINARY_ADD_PATCH))
    delete_diff = described_class.new.parse(source_for(PatchUtil::SpecHelpers::BINARY_DELETE_PATCH))

    add_diff.hunks.map(&:label).should
    add_diff.hunks.first.binary?.should
    add_diff.hunks.first.change_lines.first.text.should

    delete_diff.hunks.map(&:label).should
    delete_diff.hunks.first.binary?.should
    delete_diff.hunks.first.change_lines.first.text.should == 'binary delete image.bin'
  end

  it 'parses binary rename plus payload as separate path and payload hunks' do
    diff = described_class.new.parse(source_for(PatchUtil::SpecHelpers::BINARY_RENAME_CHANGE_PATCH))

    diff.hunks.map(&:label).should
    diff.hunks.first.operation?.should
    diff.hunks.first.change_lines.first.text.should
    diff.hunks.last.binary?.should
    diff.hunks.last.change_lines.first.text.should == 'binary lib/new.bin'
  end
end

RSpec.describe PatchUtil::Selection::Parser do
  subject(:parser) { described_class.new }

  it 'expands whole-hunk ranges into individual whole-hunk selectors' do
    selectors = parser.parse('a-c,z-ab')

    selectors.map(&:hunk_label).should
    selectors.map(&:whole_hunk?).should == [true, true, true, true, true, true]
  end

  it 'rejects descending whole-hunk ranges' do
    proc { parser.parse('c-a') }
      .should raise_error(PatchUtil::ValidationError, /descending hunk range: c-a/)
  end
end
