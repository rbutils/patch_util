# frozen_string_literal: true

RSpec.describe PatchUtil::Split::Verifier do
  subject(:verifier) { described_class.new }

  let(:diff) { parsed_diff }

  it 'rejects whole-hunk and partial selection of the same hunk' do
    request = PatchUtil::Split::ChunkRequest.new(name: 'bad', selector_text: 'a,a1', leftovers: false)

    proc { verifier.build_chunks(diff: diff, chunk_requests: [request]) }
      .should raise_error(PatchUtil::ValidationError, /whole hunk a and partial changed lines/)
  end

  it 'reports uncovered changed lines when no leftovers chunk exists' do
    request = PatchUtil::Split::ChunkRequest.new(name: 'remove old', selector_text: 'a1', leftovers: false)

    proc { verifier.build_chunks(diff: diff, chunk_requests: [request]) }
      .should raise_error(PatchUtil::ValidationError, /1 lines will be removed/)
  end

  it 'assigns uncovered lines to an explicit leftovers chunk' do
    requests = [
      PatchUtil::Split::ChunkRequest.new(name: 'remove old', selector_text: 'a1', leftovers: false),
      PatchUtil::Split::ChunkRequest.new(name: 'leftovers', selector_text: nil, leftovers: true)
    ]

    chunks = verifier.build_chunks(diff: diff, chunk_requests: requests)

    chunks.length.should
    chunks.last.leftovers?.should
    chunks.last.change_labels.should == ['a2']
  end

  it 'supports whole-hunk ranges inside one selector token' do
    request = PatchUtil::Split::ChunkRequest.new(name: 'all hunks', selector_text: 'a-b', leftovers: false)

    chunks = verifier.build_chunks(diff: parsed_diff(PatchUtil::SpecHelpers::OFFSET_PATCH), chunk_requests: [request])

    chunks.length.should
    chunks.first.change_labels.should == %w[a1 b1]
  end
end
