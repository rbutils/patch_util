# frozen_string_literal: true

module PatchUtil
  module Selection
    WholeHunk = Data.define(:hunk_label) do
      def whole_hunk?
        true
      end
    end

    ChangedLineRange = Data.define(:hunk_label, :start_ordinal, :end_ordinal) do
      def whole_hunk?
        false
      end

      def ordinals
        (start_ordinal..end_ordinal).to_a
      end
    end

    class Parser
      def parse(selector_text)
        tokens = selector_text.to_s.split(',').map(&:strip).reject(&:empty?)
        selectors = []

        tokens.each do |token|
          selectors.concat(parse_token(token))
        end

        selectors
      end

      private

      def parse_token(token)
        if (match = /\A([a-z]+)(\d+)-([a-z]+)(\d+)\z/.match(token))
          start_hunk = match[1]
          finish_hunk = match[3]
          raise ValidationError, "cross-hunk ranges are not supported: #{token}" unless start_hunk == finish_hunk

          start_ordinal = Integer(match[2], 10)
          end_ordinal = Integer(match[4], 10)
          raise ValidationError, "descending selector range: #{token}" if start_ordinal > end_ordinal

          return [ChangedLineRange.new(
            hunk_label: start_hunk,
            start_ordinal: start_ordinal,
            end_ordinal: end_ordinal
          )]
        end

        if (match = /\A([a-z]+)(\d+)\z/.match(token))
          ordinal = Integer(match[2], 10)
          return [ChangedLineRange.new(hunk_label: match[1], start_ordinal: ordinal, end_ordinal: ordinal)]
        end

        if (match = /\A([a-z]+)-([a-z]+)\z/.match(token))
          start_label = match[1]
          end_label = match[2]
          start_index = hunk_label_index(start_label)
          end_index = hunk_label_index(end_label)
          raise ValidationError, "descending hunk range: #{token}" if start_index > end_index

          return (start_index..end_index).map do |index|
            WholeHunk.new(hunk_label: hunk_label_for(index))
          end
        end

        return [WholeHunk.new(hunk_label: token)] if /\A[a-z]+\z/.match?(token)

        raise ValidationError, "invalid selector token: #{token}"
      end

      def hunk_label_index(label)
        value = 0

        label.each_byte do |byte|
          value = (value * 26) + (byte - 96)
        end

        value - 1
      end

      def hunk_label_for(index)
        current = index
        label = +''

        loop do
          label.prepend((97 + (current % 26)).chr)
          current = (current / 26) - 1
          break if current.negative?
        end

        label
      end
    end
  end
end
