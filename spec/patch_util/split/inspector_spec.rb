# frozen_string_literal: true

RSpec.describe PatchUtil::Split::Inspector do
  it 'renders grouped compact label ranges for text hunks with plan overlay' do
    diff = parsed_diff(PatchUtil::SpecHelpers::NEW_FILE_PATCH)
    source = source_for(PatchUtil::SpecHelpers::NEW_FILE_PATCH)
    plan_entry = PatchUtil::Split::Planner.new.build(
      source: source,
      diff: diff,
      chunk_requests: [
        PatchUtil::Split::ChunkRequest.new(name: 'first lines', selector_text: 'a1-a2', leftovers: false),
        PatchUtil::Split::ChunkRequest.new(name: 'last line', selector_text: 'a3', leftovers: false)
      ]
    )

    rendered = described_class.new.render(diff: diff, plan_entry: plan_entry, compact: true)

    rendered.should include('== Compact Inspect ==')
    rendered.should include('== File Index ==')
    rendered.should include('b/new_file.rb (1 hunk, 3 changes): a(text, 3 changes: a1-a2 [first lines], a3 [last line])')
    rendered.should include('== Details ==')
    rendered.should include('--- /dev/null')
    rendered.should include('+++ b/new_file.rb')
    rendered.should include('a text @@ -0,0 +1,3 @@: a1-a2 [first lines], a3 [last line]')
  end

  it 'renders operation and text hunks distinctly in compact mode' do
    diff = parsed_diff(PatchUtil::SpecHelpers::RENAME_PATCH)

    rendered = described_class.new.render(diff: diff, compact: true)

    rendered.should include('b/lib/new.rb (2 hunks, 3 changes): b(text, 2 changes: b1-b2); a(operation, 1 change: a1)')
    rendered.should include('--- a/lib/old.rb')
    rendered.should include('+++ b/lib/new.rb')
    rendered.should include('a operation: a1 =rename lib/old.rb -> lib/new.rb (71%)')
    rendered.should include('b text @@ -1,3 +1,3 @@: b1-b2')
    rendered.should_not include('-one')
    rendered.should_not include('+ONE')
  end

  it 'orders compact file-index hunks by descending change count' do
    diff = parsed_diff(PatchUtil::SpecHelpers::OFFSET_PATCH)

    rendered = described_class.new.render(diff: diff, compact: true)

    rendered.should include('b/example.rb (2 hunks, 2 changes): a(text, 1 change: a1); b(text, 1 change: b1)')
    rendered.index('b/example.rb (2 hunks, 2 changes):').should be < rendered.index('== Details ==')
    rendered.index('a text @@ -1,4 +1,3 @@: a1').should be < rendered.index('b text @@ -10,4 +9,5 @@: b1')
  end

  it 'expands only selected hunks inside compact details' do
    diff = parsed_diff(PatchUtil::SpecHelpers::RENAME_PATCH)

    rendered = described_class.new.render(diff: diff, compact: true, expand_hunks: ['b'])

    rendered.should include('expanded hunks: b')
    rendered.should include('a operation: a1 =rename lib/old.rb -> lib/new.rb (71%)')
    rendered.should include('b text @@ -1,3 +1,3 @@: b1-b2 [expanded]')
    rendered.should include('@@ -1,3 +1,3 @@')
    rendered.should include('b1                           -one')
    rendered.should include('b2                           +ONE')
    rendered.should_not include('a1                           =rename')
  end
end
