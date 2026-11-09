# frozen_string_literal: true

require "digest"
require "json"

module Doparserb
  module Play
    class Protocol
      MAX_DATAGRAM_BYTES = 2048
      MAX_METADATA_BYTES = 1_048_576
      MAX_METADATA_ENTRIES = 32
      MAX_FRAGMENTS = 1024
      MAX_SIDECARS = 128
      RESOLVER_JOIN_TIMEOUT = 0.01
      INTEGER_RANGE = (-(2**63)..(2**64 - 1))
      ARGUMENTS = {"B" => [], "T" => %i[sym line col], "S" => %i[sym state depth],
                   "R" => %i[rule len state depth], "E" => %i[state sym line col],
                   "P" => %i[n depth], "X" => %i[state depth], "Q" => [:n], "I" => [:sym],
                   "C" => [], "A" => [], "Z" => [], "O" => [], "D" => [:n]}.freeze

      def initialize(executable:, directory: Dir.pwd)
        @directory = File.expand_path(directory)
        @executable = executable
        @entries = {}
        @metadata_mutex = Mutex.new
        @resolver_queue = SizedQueue.new(MAX_METADATA_ENTRIES)
        @updates = {}
        @closed = false
      end

      def consume(datagram)
        return [] if @closed
        return [] unless datagram.is_a?(String) && datagram.bytesize <= MAX_DATAGRAM_BYTES

        bytes = datagram.b
        header_end = bytes.index("\n")
        return [] unless header_end

        header = bytes.byteslice(0, header_end).split(" ")
        return [] unless header.length == 4 && header[0] == "F" && parser_id?(header[1])

        pid, parse_id = header.drop(2).map { |value| integer(value) }
        return [] unless pid && pid.positive? && parse_id && parse_id.positive?

        identity = {parser: header[1].downcase.freeze, pid: pid, parse_id: parse_id}
        events = []
        offset = header_end + 1
        while (line_end = bytes.index("\n", offset))
          fields = bytes.byteslice(offset, line_end - offset).split(" ")
          offset = line_end + 1
          if fields[0] == "M" && fields.length == 4 && parser_id?(fields[1]) && fields.drop(2).all? { |value| integer(value) }
            @metadata_mutex.synchronize { receive_metadata(identity, fields, bytes.byteslice(offset..)) }
            break
          end
          event = event_line(fields, identity)
          events << event if event
        end
        events
      end

      def metadata(parser, pid)
        @metadata_mutex.synchronize { @entries[[parser, pid]]&.fetch(:metadata, nil) }
      end

      def drain_updates
        @metadata_mutex.synchronize do
          @updates.values.tap { @updates.clear }
        end
      end

      def close
        worker = @metadata_mutex.synchronize do
          @closed = true
          @resolver_queue.close
          @resolver_queue.clear
          @updates.clear
          @resolver_thread
        end
        worker&.kill
        worker&.join(RESOLVER_JOIN_TIMEOUT)
        nil
      end

      private

      def parser_id?(value)
        /\A[0-9a-fA-F]{8}\z/.match?(value)
      end

      def integer(value)
        return unless value && /\A-?[0-9]{1,20}\z/.match?(value)
        number = value.to_i
        number if INTEGER_RANGE.cover?(number)
      end

      def event_line(fields, identity)
        code = fields.first
        names = ARGUMENTS[code]
        return unless names && fields.length == names.length + 1
        values = fields.drop(1).map { |value| integer(value) }
        return if values.any?(&:nil?)
        args = names.zip(values).to_h
        return if args.any? { |key, value| %i[state depth rule len n].include?(key) && value.negative? }
        identity.merge(code: code.freeze).merge(args).freeze
      end

      def receive_metadata(identity, fields, bytes)
        return if @closed
        parser = identity[:parser]
        return unless fields[1].downcase == parser
        key = [parser, identity[:pid]]
        offset, total = fields.drop(2).map { |value| integer(value) }
        return unless offset && total && offset >= 0 && total.positive? &&
                      total <= MAX_METADATA_BYTES && !bytes.empty? && offset + bytes.bytesize <= total

        unless @entries.key?(key)
          @updates.delete(@entries.shift.first) if @entries.length >= MAX_METADATA_ENTRIES
          @entries[key] = {total: total, parts: {}}
        end
        entry = @entries[key]
        return if entry[:invalid]
        if total != entry[:total]
          @entries[key] = {invalid: true}
          @updates.delete(key)
          return
        end
        if entry[:payload]
          unless entry[:payload].byteslice(offset, bytes.bytesize) == bytes
            @entries[key] = {invalid: true}
            @updates.delete(key)
          end
          return
        end
        parts = entry[:parts]
        range = [offset, bytes.bytesize]
        return if parts[range] == bytes
        conflict = parts.any? do |(start, length), part|
          first = [start, offset].max
          last = [start + length, offset + bytes.bytesize].min
          first < last && part.byteslice(first - start, last - first) != bytes.byteslice(first - offset, last - first)
        end
        if parts.length >= MAX_FRAGMENTS || conflict
          @entries[key] = {invalid: true}
          return
        end
        parts[range] = bytes
        payload = assemble(parts, total)
        return unless payload

        data = decode_metadata(payload, parser)
        entry = @entries[key] = {total: total, payload: payload}
        if data && !data.key?("symbols")
          resolve_sidecar(key, entry, data)
        else
          entry[:metadata] = freeze_metadata(data)
        end
      end

      def resolve_sidecar(key, entry, stub)
        @resolver_thread ||= Thread.new do
          Thread.current.priority = -1
          while (job = @resolver_queue.pop)
            resolve_job(*job)
          end
        end
        @resolver_queue.push([key, entry, stub], true)
      rescue ThreadError
        nil
      end

      def resolve_job(key, entry, stub)
        data = freeze_metadata(find_sidecar(stub, key.first))
        @metadata_mutex.synchronize do
          return if @closed || !@entries[key].equal?(entry)
          entry[:metadata] = data
          @updates[key] = [*key, data].freeze if data
        end
      rescue StandardError => error
        Doparserb.debug(error)
      end

      def assemble(parts, total)
        ordered = parts.sort_by { |(offset, _), _| offset }
        covered = 0
        ordered.each do |(offset, length), _|
          return if offset > covered
          covered = [covered, offset + length].max
        end
        return unless covered == total
        payload = +"".b
        ordered.each do |(offset, length), bytes|
          next if offset + length <= payload.bytesize
          payload << bytes.byteslice([payload.bytesize - offset, 0].max..)
        end
        payload
      end

      def decode_metadata(bytes, parser)
        data = JSON.parse(bytes)
        return unless data.is_a?(Hash) && data["v"] == 1 && data["grammar"].is_a?(String) &&
                      data["generator"].is_a?(String) && /\A[0-9a-f]{64}\z/.match?(data["digest"].to_s) &&
                      data["digest"].start_with?(parser)
        return data if data.keys.sort == %w[digest generator grammar v]
        return unless valid_tables?(data)
        return unless Digest::SHA256.hexdigest(JSON.generate(data.reject { |key, _| key == "digest" })) == data["digest"]
        data
      rescue JSON::ParserError, EncodingError, ArgumentError
        nil
      end

      def valid_tables?(data)
        data["states"].is_a?(Integer) && data["states"] >= 0 &&
          data["symbols"].is_a?(Array) && data["symbols"].all? do |symbol|
            symbol.is_a?(Hash) && nonnegative_integer?(symbol["id"]) && symbol["name"].is_a?(String) &&
              [true, false].include?(symbol["term"])
          end && data["rules"].is_a?(Array) && data["rules"].all? do |rule|
            rule.is_a?(Hash) && nonnegative_integer?(rule["id"]) && nonnegative_integer?(rule["lhs"]) &&
              rule["text"].is_a?(String) && rule["rhs"].is_a?(Array) && rule["rhs"].all? { |id| nonnegative_integer?(id) }
          end
      end

      def nonnegative_integer?(value)
        value.is_a?(Integer) && value >= 0
      end

      def find_sidecar(stub, parser)
        [@directory, executable_directory].compact.uniq.each do |directory|
          checked = 0
          Dir.each_child(directory) do |name|
            Thread.pass
            next unless name.end_with?(".dopa.json")
            break if checked >= MAX_SIDECARS
            checked += 1
            path = File.join(directory, name)
            next unless File.file?(path)
            begin
              bytes = File.binread(path, MAX_METADATA_BYTES + 1)
              next if bytes.bytesize > MAX_METADATA_BYTES
              data = decode_metadata(bytes, parser)
              return data if data && data.key?("symbols") && data["digest"] == stub["digest"]
            rescue SystemCallError, IOError
              next
            end
          end
        rescue SystemCallError, IOError
          next
        end
        nil
      end

      def executable_directory
        return unless @executable && !@executable.empty?
        path = if @executable.include?(File::SEPARATOR)
          File.expand_path(@executable, @directory)
        else
          ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |directory| File.expand_path(@executable, directory) }
            .find { |candidate| File.file?(candidate) && File.executable?(candidate) }
        end
        File.dirname(File.realpath(path)) if path
      rescue SystemCallError, IOError
        nil
      end

      def freeze_metadata(value)
        case value
        when Hash
          value.each { |key, item| key.freeze; freeze_metadata(item) }
        when Array
          value.each { |item| freeze_metadata(item) }
        end
        value.freeze
      end
    end
  end
end
