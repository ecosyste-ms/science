class RorJsonReader
  def self.each_record(io, offset: 0)
    io.seek(offset)
    state = offset.zero? ? :start : :separator
    depth = 0
    quoted = false
    escaped = false
    record = String.new(encoding: Encoding::BINARY)

    while (chunk = io.read(64 * 1024))
      chunk.each_byte do |byte|
        offset += 1
        if state == :record
          record << byte
          if quoted
            if escaped
              escaped = false
            elsif byte == 92
              escaped = true
            elsif byte == 34
              quoted = false
            end
          elsif byte == 34
            quoted = true
          elsif byte == 123
            depth += 1
          elsif byte == 125
            depth -= 1
            if depth.zero?
              yield JSON.parse(record.force_encoding(Encoding::UTF_8)), offset
              record = String.new(encoding: Encoding::BINARY)
              state = :separator
            end
          end
          next
        end
        next if [9, 10, 13, 32].include?(byte)

        case state
        when :start
          raise ArgumentError, "ROR JSON must be an array" unless byte == 91
          state = :first
        when :first, :next
          if byte == 93 && state == :first
            state = :finished
          elsif byte == 123
            state = :record
            depth = 1
            record << byte
          else
            raise ArgumentError, "Expected a ROR record"
          end
        when :separator
          state = case byte
          when 44 then :next
          when 93 then :finished
          else raise ArgumentError, "Expected a ROR record separator"
          end
        when :finished
          raise ArgumentError, "Unexpected data after ROR array"
        end
      end
    end
    raise ArgumentError, "Incomplete ROR JSON array" unless state == :finished
  end
end
