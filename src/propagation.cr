require "socket"

module AtlanticDNS
  module Propagation
    RESOLVERS = [
      {"1.1.1.1", "Cloudflare"},
      {"9.9.9.9", "Quad9"},
      {"8.8.8.8", "Google"},
    ]

    DEFAULT_TIMEOUT  =  300
    DEFAULT_INTERVAL =    5

    # Blocks until every resolver in RESOLVERS returns *expected_ip* for the A
    # record of *fqdn*, or until *timeout* seconds have elapsed.  Returns true
    # on success, false on timeout.  Progress is written to STDERR.
    def self.wait_for_a_record(fqdn : String, expected_ip : String,
                                timeout : Int32 = DEFAULT_TIMEOUT,
                                interval : Int32 = DEFAULT_INTERVAL) : Bool
      deadline = Time.utc + timeout.seconds
      STDERR.puts "Waiting for DNS propagation of #{fqdn} → #{expected_ip} " \
                  "(timeout #{timeout}s, checking every #{interval}s)"

      loop do
        statuses = RESOLVERS.map do |ip, label|
          seen = query_a(fqdn, ip)
          ok   = seen == expected_ip
          {label, seen, ok}
        end

        ok_count = statuses.count { |_, _, ok| ok }
        status_line = statuses.map { |label, seen, ok|
          "#{label}:#{ok ? "✓" : (seen || "?")} "
        }.join
        STDERR.print "\r  #{status_line.rstrip}"
        STDERR.flush

        if ok_count == RESOLVERS.size
          STDERR.puts "\n  All resolvers agree — propagation complete."
          return true
        end

        if Time.utc >= deadline
          STDERR.puts "\n  Timed out after #{timeout}s — not all resolvers have the new value."
          return false
        end

        sleep interval.seconds
      end
    end

    # Sends a single UDP A-record query to *server*:53 and returns the first
    # A record in the answer section, or nil on any error/no-answer.
    def self.query_a(fqdn : String, server : String, port : Int32 = 53) : String?
      socket = UDPSocket.new
      socket.connect(server, port)
      socket.read_timeout = 3.seconds
      socket.send(build_query(fqdn, 1_u16))
      buf = Bytes.new(512)
      n, _ = socket.receive(buf)
      parse_a_response(buf[0, n])
    rescue
      nil
    ensure
      socket.try(&.close)
    end

    # ── private helpers ────────────────────────────────────────────────────

    private def self.build_query(fqdn : String, qtype : UInt16) : Bytes
      io = IO::Memory.new
      io.write_bytes(rand(0xFFFF).to_u16, IO::ByteFormat::BigEndian) # transaction ID
      io.write_bytes(0x0100_u16, IO::ByteFormat::BigEndian)           # flags: RD=1
      io.write_bytes(1_u16, IO::ByteFormat::BigEndian)                # QDCOUNT
      io.write_bytes(0_u16, IO::ByteFormat::BigEndian)                # ANCOUNT
      io.write_bytes(0_u16, IO::ByteFormat::BigEndian)                # NSCOUNT
      io.write_bytes(0_u16, IO::ByteFormat::BigEndian)                # ARCOUNT
      fqdn.rstrip('.').split('.').each do |label|
        bytes = label.to_slice
        io.write_byte(bytes.size.to_u8)
        io.write(bytes)
      end
      io.write_byte(0_u8)
      io.write_bytes(qtype, IO::ByteFormat::BigEndian)
      io.write_bytes(1_u16, IO::ByteFormat::BigEndian) # QCLASS IN
      io.to_slice
    end

    private def self.parse_a_response(buf : Bytes) : String?
      return nil if buf.size < 12
      ancount = (buf[6].to_u16 << 8) | buf[7].to_u16
      return nil if ancount == 0

      pos = 12
      # Skip question QNAME (no compression in questions)
      while pos < buf.size && buf[pos] != 0
        pos += buf[pos].to_i + 1
      end
      pos += 1  # null terminator
      pos += 4  # QTYPE + QCLASS
      return nil if pos > buf.size

      # Walk answer RRs looking for the first A record
      ancount.times do
        break if pos >= buf.size
        # NAME field: pointer (0xC0) or inline labels
        if (buf[pos] & 0xC0) == 0xC0
          pos += 2
        else
          while pos < buf.size && buf[pos] != 0
            pos += buf[pos].to_i + 1
          end
          pos += 1
        end
        break if pos + 10 > buf.size
        rtype  = (buf[pos].to_u16 << 8) | buf[pos + 1].to_u16
        pos   += 8  # TYPE(2) + CLASS(2) + TTL(4)
        rdlen  = (buf[pos].to_u16 << 8) | buf[pos + 1].to_u16
        pos   += 2
        if rtype == 1_u16 && rdlen == 4 && pos + 4 <= buf.size
          return "#{buf[pos]}.#{buf[pos + 1]}.#{buf[pos + 2]}.#{buf[pos + 3]}"
        end
        pos += rdlen.to_i
      end
      nil
    end
  end
end
