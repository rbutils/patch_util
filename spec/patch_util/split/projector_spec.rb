# frozen_string_literal: true

RSpec.describe PatchUtil::Split::Projector do
  let(:planner) { PatchUtil::Split::Planner.new }
  let(:emitter) { PatchUtil::Split::Emitter.new }

  it 'emits deletion-only and addition-only patches from one original replacement' do
    diff = parsed_diff
    source = source_for
    plan_entry = planner.build(
      source: source,
      diff: diff,
      chunk_requests: [
        PatchUtil::Split::ChunkRequest.new(name: 'remove old', selector_text: 'a1', leftovers: false),
        PatchUtil::Split::ChunkRequest.new(name: 'add new', selector_text: 'a2', leftovers: false)
      ]
    )

    projector = described_class.new(diff: diff, plan_entry: plan_entry)
    first_patch = emitter.emit(projector.project_chunk(0))
    second_patch = emitter.emit(projector.project_chunk(1))

    first_patch.should include('@@ -1,5 +1,4 @@')
    first_patch.should include('-  do_something();')
    first_patch.should_not include('+  do_something_else();')

    second_patch.should include('@@ -1,4 +1,5 @@')
    second_patch.should include('+  do_something_else();')
    second_patch.should_not include('-  do_something();')
  end

  it 'recomputes later hunk offsets after earlier chunk deltas' do
    diff = parsed_diff(PatchUtil::SpecHelpers::OFFSET_PATCH)
    source = source_for(PatchUtil::SpecHelpers::OFFSET_PATCH)
    plan_entry = planner.build(
      source: source,
      diff: diff,
      chunk_requests: [
        PatchUtil::Split::ChunkRequest.new(name: 'remove first', selector_text: 'a1', leftovers: false),
        PatchUtil::Split::ChunkRequest.new(name: 'add second', selector_text: 'b1', leftovers: false)
      ]
    )

    projector = described_class.new(diff: diff, plan_entry: plan_entry)
    second_patch = emitter.emit(projector.project_chunk(1))

    second_patch.should include('@@ -9,3 +8,4 @@')
    second_patch.should include('+  do_other();')
  end

  it 'emits split patches for newly added files' do
    diff = parsed_diff(PatchUtil::SpecHelpers::NEW_FILE_PATCH)
    source = source_for(PatchUtil::SpecHelpers::NEW_FILE_PATCH)
    plan_entry = planner.build(
      source: source,
      diff: diff,
      chunk_requests: [
        PatchUtil::Split::ChunkRequest.new(name: 'first lines', selector_text: 'a1-a2', leftovers: false),
        PatchUtil::Split::ChunkRequest.new(name: 'last line', selector_text: 'a3', leftovers: false)
      ]
    )

    projector = described_class.new(diff: diff, plan_entry: plan_entry)
    first_patch = emitter.emit(projector.project_chunk(0))
    second_patch = emitter.emit(projector.project_chunk(1))

    first_patch.should include('--- /dev/null')
    first_patch.should include('+++ b/new_file.rb')
    first_patch.should include('@@ -0,0 +1,2 @@')
    first_patch.should include('+line one')
    first_patch.should include('+line two')

    second_patch.should include('@@ -0,2 +1,3 @@')
    second_patch.should include(' line one')
    second_patch.should include(' line two')
    second_patch.should include('+line three')
  end

  it 'emits split patches for deleted files' do
    diff = parsed_diff(PatchUtil::SpecHelpers::DELETE_FILE_PATCH)
    source = source_for(PatchUtil::SpecHelpers::DELETE_FILE_PATCH)
    plan_entry = planner.build(
      source: source,
      diff: diff,
      chunk_requests: [
        PatchUtil::Split::ChunkRequest.new(name: 'drop first line', selector_text: 'a1', leftovers: false),
        PatchUtil::Split::ChunkRequest.new(name: 'drop rest', selector_text: 'a2-a3', leftovers: false)
      ]
    )

    projector = described_class.new(diff: diff, plan_entry: plan_entry)
    first_patch = emitter.emit(projector.project_chunk(0))
    second_patch = emitter.emit(projector.project_chunk(1))

    first_patch.should include('--- a/old_file.rb')
    first_patch.should include('+++ /dev/null')
    first_patch.should include('@@ -1,3 +0,2 @@')
    first_patch.should include('-line one')

    second_patch.should include('@@ -1,2 +0,0 @@')
    second_patch.should include('-line two')
    second_patch.should include('-line three')
  end

  it 'preserves new file mode metadata for text additions in mixed chunks' do
    diff = parsed_diff(PatchUtil::SpecHelpers::MIXED_MODIFY_AND_NEW_FILE_PATCH)
    source = source_for(PatchUtil::SpecHelpers::MIXED_MODIFY_AND_NEW_FILE_PATCH)
    plan_entry = planner.build(
      source: source,
      diff: diff,
      chunk_requests: [
        PatchUtil::Split::ChunkRequest.new(name: 'mixed chunk', selector_text: 'a,b', leftovers: false)
      ]
    )

    patch_text = emitter.emit(described_class.new(diff: diff, plan_entry: plan_entry).project_chunk(0))

    patch_text.should include('diff --git a/lib/existing.rb b/lib/existing.rb')
    patch_text.should include('diff --git a/lib/new_file.rb b/lib/new_file.rb')
    patch_text.should include('new file mode 100644')
    patch_text.should include('--- /dev/null')
    patch_text.should include('+++ b/lib/new_file.rb')
  end

  it 'emits a rename operation as its own chunk before later text edits' do
    diff = parsed_diff(PatchUtil::SpecHelpers::RENAME_PATCH)
    source = source_for(PatchUtil::SpecHelpers::RENAME_PATCH)
    plan_entry = planner.build(
      source: source,
      diff: diff,
      chunk_requests: [
        PatchUtil::Split::ChunkRequest.new(name: 'rename file', selector_text: 'a', leftovers: false),
        PatchUtil::Split::ChunkRequest.new(name: 'edit body', selector_text: 'b', leftovers: false)
      ]
    )

    projector = described_class.new(diff: diff, plan_entry: plan_entry)
    first_patch = emitter.emit(projector.project_chunk(0))
    second_patch = emitter.emit(projector.project_chunk(1))

    first_patch.should include('diff --git a/lib/old.rb b/lib/new.rb')
    first_patch.should include('similarity index 71%')
    first_patch.should include('rename from lib/old.rb')
    first_patch.should include('rename to lib/new.rb')
    first_patch.should include('--- a/lib/old.rb')
    first_patch.should include('+++ b/lib/new.rb')
    first_patch.should_not include('@@ -1,3 +1,3 @@')

    second_patch.should include('diff --git a/lib/new.rb b/lib/new.rb')
    second_patch.should include('--- a/lib/new.rb')
    second_patch.should include('+++ b/lib/new.rb')
    second_patch.should include('@@ -1,3 +1,3 @@')
    second_patch.should include('-one')
    second_patch.should include('+ONE')
    second_patch.should_not include('rename from lib/old.rb')
  end

  it 'emits metadata-only rename chunks without text hunks' do
    diff = parsed_diff(PatchUtil::SpecHelpers::RENAME_ONLY_PATCH)
    source = source_for(PatchUtil::SpecHelpers::RENAME_ONLY_PATCH)
    plan_entry = planner.build(
      source: source,
      diff: diff,
      chunk_requests: [
        PatchUtil::Split::ChunkRequest.new(name: 'rename file', selector_text: 'a', leftovers: false)
      ]
    )

    patch_text = emitter.emit(described_class.new(diff: diff, plan_entry: plan_entry).project_chunk(0))

    patch_text.should include('diff --git a/lib/old.rb b/lib/new.rb')
    patch_text.should include('similarity index 100%')
    patch_text.should include('rename from lib/old.rb')
    patch_text.should include('rename to lib/new.rb')
    patch_text.should include('--- a/lib/old.rb')
    patch_text.should include('+++ b/lib/new.rb')
    patch_text.should_not include('@@ ')
  end

  it 'emits metadata-only mode changes as operation-only chunks' do
    diff = parsed_diff(PatchUtil::SpecHelpers::MODE_PATCH)
    source = source_for(PatchUtil::SpecHelpers::MODE_PATCH)
    plan_entry = planner.build(
      source: source,
      diff: diff,
      chunk_requests: [
        PatchUtil::Split::ChunkRequest.new(name: 'make executable', selector_text: 'a', leftovers: false)
      ]
    )

    patch_text = emitter.emit(described_class.new(diff: diff, plan_entry: plan_entry).project_chunk(0))

    patch_text.should include('diff --git a/bin/tool b/bin/tool')
    patch_text.should include('old mode 100644')
    patch_text.should include('new mode 100755')
    patch_text.should include('--- a/bin/tool')
    patch_text.should include('+++ b/bin/tool')
    patch_text.should_not include('@@ ')
  end

  it 'keeps combined rename and mode metadata with the operation chunk' do
    diff = parsed_diff(PatchUtil::SpecHelpers::RENAME_WITH_MODE_PATCH)
    source = source_for(PatchUtil::SpecHelpers::RENAME_WITH_MODE_PATCH)
    plan_entry = planner.build(
      source: source,
      diff: diff,
      chunk_requests: [
        PatchUtil::Split::ChunkRequest.new(name: 'move and chmod', selector_text: 'a', leftovers: false),
        PatchUtil::Split::ChunkRequest.new(name: 'edit body', selector_text: 'b', leftovers: false)
      ]
    )

    projector = described_class.new(diff: diff, plan_entry: plan_entry)
    first_patch = emitter.emit(projector.project_chunk(0))
    second_patch = emitter.emit(projector.project_chunk(1))

    first_patch.should include('diff --git a/lib/old.rb b/lib/new.rb')
    first_patch.should include('old mode 100644')
    first_patch.should include('new mode 100755')
    first_patch.should include('similarity index 71%')
    first_patch.should include('rename from lib/old.rb')
    first_patch.should include('rename to lib/new.rb')
    first_patch.should_not include('@@ -1,3 +1,3 @@')

    second_patch.should include('diff --git a/lib/new.rb b/lib/new.rb')
    second_patch.should include('--- a/lib/new.rb')
    second_patch.should include('+++ b/lib/new.rb')
    second_patch.should include('@@ -1,3 +1,3 @@')
    second_patch.should_not include('old mode 100644')
    second_patch.should_not include('rename from lib/old.rb')
  end

  it 'emits binary modification payloads as standalone chunks' do
    diff = parsed_diff(PatchUtil::SpecHelpers::BINARY_PATCH)
    source = source_for(PatchUtil::SpecHelpers::BINARY_PATCH)
    plan_entry = planner.build(
      source: source,
      diff: diff,
      chunk_requests: [
        PatchUtil::Split::ChunkRequest.new(name: 'binary update', selector_text: 'a', leftovers: false)
      ]
    )

    patch_text = emitter.emit(described_class.new(diff: diff, plan_entry: plan_entry).project_chunk(0))

    patch_text.should include('diff --git a/image.bin b/image.bin')
    patch_text.should include('index c86626638e0bc8cf47ca49bb1525b40e9737ee64..5663091be8ca2b5e57d3c2323a38840a729caf66 100644')
    patch_text.should include('--- a/image.bin')
    patch_text.should include('+++ b/image.bin')
    patch_text.should include('GIT binary patch')
    patch_text.should include('literal 256')
    patch_text.should_not include('@@ ')
  end

  it 'emits binary add payloads without text headers' do
    diff = parsed_diff(PatchUtil::SpecHelpers::BINARY_ADD_PATCH)
    source = source_for(PatchUtil::SpecHelpers::BINARY_ADD_PATCH)
    plan_entry = planner.build(
      source: source,
      diff: diff,
      chunk_requests: [
        PatchUtil::Split::ChunkRequest.new(name: 'add binary', selector_text: 'a', leftovers: false)
      ]
    )

    patch_text = emitter.emit(described_class.new(diff: diff, plan_entry: plan_entry).project_chunk(0))

    patch_text.should include('diff --git a/image.bin b/image.bin')
    patch_text.should include('new file mode 100644')
    patch_text.should include('GIT binary patch')
    patch_text.should_not include('--- /dev/null')
    patch_text.should_not include('+++ b/image.bin')
  end

  it 'emits binary delete payloads without text headers' do
    diff = parsed_diff(PatchUtil::SpecHelpers::BINARY_DELETE_PATCH)
    source = source_for(PatchUtil::SpecHelpers::BINARY_DELETE_PATCH)
    plan_entry = planner.build(
      source: source,
      diff: diff,
      chunk_requests: [
        PatchUtil::Split::ChunkRequest.new(name: 'delete binary', selector_text: 'a', leftovers: false)
      ]
    )

    patch_text = emitter.emit(described_class.new(diff: diff, plan_entry: plan_entry).project_chunk(0))

    patch_text.should include('diff --git a/image.bin b/image.bin')
    patch_text.should include('deleted file mode 100644')
    patch_text.should include('GIT binary patch')
    patch_text.should_not include('--- a/image.bin')
    patch_text.should_not include('+++ /dev/null')
  end

  it 'splits binary rename plus payload into valid path and payload chunks' do
    diff = parsed_diff(PatchUtil::SpecHelpers::BINARY_RENAME_CHANGE_PATCH)
    source = source_for(PatchUtil::SpecHelpers::BINARY_RENAME_CHANGE_PATCH)
    plan_entry = planner.build(
      source: source,
      diff: diff,
      chunk_requests: [
        PatchUtil::Split::ChunkRequest.new(name: 'rename binary', selector_text: 'a', leftovers: false),
        PatchUtil::Split::ChunkRequest.new(name: 'update binary', selector_text: 'b', leftovers: false)
      ]
    )

    projector = described_class.new(diff: diff, plan_entry: plan_entry)
    first_patch = emitter.emit(projector.project_chunk(0))
    second_patch = emitter.emit(projector.project_chunk(1))

    first_patch.should include('diff --git a/lib/old.bin b/lib/new.bin')
    first_patch.should include('similarity index 95%')
    first_patch.should include('rename from lib/old.bin')
    first_patch.should include('rename to lib/new.bin')
    first_patch.should include('--- a/lib/old.bin')
    first_patch.should include('+++ b/lib/new.bin')
    first_patch.should_not include('GIT binary patch')

    second_patch.should include('diff --git a/lib/new.bin b/lib/new.bin')
    second_patch.should include('index c86626638e0bc8cf47ca49bb1525b40e9737ee64..0aaa0f198cef816245eb1dc21ce8b1ffe2e61584 100644')
    second_patch.should include('--- a/lib/new.bin')
    second_patch.should include('+++ b/lib/new.bin')
    second_patch.should include('GIT binary patch')
    second_patch.should include('delta 9')
    second_patch.should_not include('rename from lib/old.bin')
  end
end
