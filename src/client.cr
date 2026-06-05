require "http/client"
require "json"
require "openssl/hmac"
require "base64"
require "random"
require "uri"
require "process"
require "./types"

module AtlanticDNS
  BASE_URL    = "https://cloudapi.atlantic.net/"
  API_VERSION = "2010-12-30"

  # ─── KeepassXC credential lookup ──────────────────────────────────

  module KeepassXC
    DEFAULT_ENTRY = "atlanticnet"

    # Return the cached master password if available (from KEEPASS_MASTER
    # env var or the runtime cache file used by the staging deploy flow).
    private def self.cached_password : String?
      ENV["KEEPASS_MASTER"]? || begin
        cache_path = "#{ENV["XDG_RUNTIME_DIR"]? || "/run/user/#{Process.pid}"}/dirless-keepass.cache"
        File.read(cache_path) rescue nil
      end
    end

    # Look up attributes from a KeepassXC entry.
    # If KEEPASS_MASTER is set (or the runtime cache file exists), pipes the
    # password to keepassxc-cli via stdin. Otherwise prompts on the TTY.
    def self.lookup(db_path : String, entry : String, attributes : Array(String),
                     command : String = "keepassxc-cli") : Array(String)
      process = Process.new(
        command,
        ["show", db_path, entry] + attributes.flat_map { |a| ["-a", a] } + ["-q"],
        input: Process::Redirect::Pipe,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe
      )

      # Pipe the password if cached, otherwise the user will be prompted on TTY
      # (keepassxc-cli reads from /dev/tty when stdin is not a terminal).
      pw = cached_password
      if pw
        process.input.puts(pw)
      end
      process.input.close

      output = process.output.gets_to_end
      error = process.error.gets_to_end.strip
      status = process.wait

      unless status.success?
        raise "keepassxc-cli failed (exit #{status.exit_code}): #{error}"
      end

      lines = output.strip.split('\n', remove_empty: true)
      if lines.size < attributes.size
        raise "keepassxc-cli returned fewer values (got #{lines.size}, expected #{attributes.size}) for '#{entry}'"
      end
      lines
    end

    # Convenience: fetch both API keys in a single DB unlock.
    def self.fetch_keys(db_path : String, entry : String = DEFAULT_ENTRY) : NamedTuple(access_key: String, private_key: String)
      values = lookup(db_path, entry, ["UserName", "Password"])
      {access_key: values[0], private_key: values[1]}
    end
  end

  # Signed HTTP client for the Atlantic.net Cloud API.
  class Client
    getter access_key : String
    getter private_key : String
    getter base_url : String
    getter? debug : Bool

    def initialize(@access_key : String, @private_key : String,
                   @base_url : String = BASE_URL, @debug : Bool = false)
    end

    # Build a random UUID (v4-style hex string).
    private def random_guid : String
      Random::Secure.hex(16)
    end

    # Compute the HMAC-SHA256 signature per Atlantic.net's auth spec.
    # msg = "#{timestamp}#{rndguid}", signed with the private key.
    private def sign(timestamp : Int64, guid : String) : String
      message = "#{timestamp}#{guid}"
      mac = OpenSSL::HMAC.digest(:sha256, @private_key.to_slice, message.to_slice)
      Base64.strict_encode(mac)
    end

    # Perform a signed GET request. Returns the parsed JSON response.
    # Raises APIError on structured API errors, or a generic Exception on
    # HTTP / parse failures.
    def api_call(action : String, extra : Hash(String, String) = {} of String => String) : JSON::Any
      ts   = Time.utc.to_unix
      guid = random_guid
      sig  = sign(ts, guid)

      params = URI::Params.build do |p|
        p.add("Action", action)
        p.add("Format", "json")
        p.add("Version", API_VERSION)
        p.add("ACSAccessKeyId", @access_key)
        p.add("Timestamp", ts.to_s)
        p.add("Rndguid", guid)
        p.add("Signature", sig)
        extra.each { |k, v| p.add(k, v) }
      end

      url = "#{@base_url}?#{params}"

      if @debug
        debug_url = url.gsub(@access_key, "***").gsub(sig, "***")
        STDERR.puts "[DEBUG] GET #{debug_url}"
      end

      response = HTTP::Client.get(url)
      body = response.body

      if @debug
        truncated = body.size > 500 ? body[0..499] + "..." : body
        STDERR.puts "[DEBUG] Response (#{action}): #{truncated}"
      end

      begin
        json = JSON.parse(body)
      rescue ex : JSON::ParseException
        raise "Failed to parse API response as JSON: #{ex.message} (body: #{body})"
      end

      # Surface API-level errors
      if err = json["error"]?
        raise APIError.new(
          err["code"].as_s,
          err["message"].as_s
        )
      end

      json
    end

    # ─── Zones ──────────────────────────────────────────────────────────

    # List all DNS zones on the account.
    def list_zones : Array(Zone)
      resp = api_call("DNS-list-zones")
      wrapper = resp["DNS-list-zonesresponse"]

      # Atlantic returns "No Zones were returned" as an error when empty.
      # Handle gracefully — return an empty array.
      zones_node = wrapper["zones"]?
      return [] of Zone if zones_node.nil?

      zones_map = extract_indexed_map(zones_node)
      zones_map.map { |_key, item|
        Zone.new(
          id:   item["zone_id"].as_s,
          name: item["zone_name"].as_s
        )
      }
    rescue ex : APIError
      return [] of Zone if ex.to_s.includes?("No Zones were returned")
      raise ex
    end

    # Resolve a zone name to its ID. Raises if not found.
    def resolve_zone_id(zone_name : String) : String
      list_zones.each do |z|
        return z.id if z.name == zone_name
      end
      raise "Zone '#{zone_name}' not found"
    end

    # ─── Records ────────────────────────────────────────────────────────

    # List all DNS records in a zone.
    def list_records(zone_id : String) : Array(Record)
      resp = api_call("DNS-list-zone-records", {"zone_id" => zone_id})
      wrapper = resp["DNS-list-zone-recordsresponse"]
      records_map = extract_indexed_map(wrapper["records"])
      records_map.map { |_key, item|
        Record.new(
          id:       item["record_id"].as_s,
          type:     item["type"].as_s,
          host:     item["host"].as_s,
          data:     item["data"].as_s,
          ttl:      item["ttl"].as_s,
          priority: item["priority"]?.try(&.as_s)
        )
      }
    end

    # Create a new DNS record in a zone.
    def create_record(zone_id : String, type : String, host : String,
                       data : String, ttl : String,
                       priority : String? = nil) : Record
      extra = {
        "zone_id" => zone_id,
        "type"    => type,
        "host"    => host,
        "data"    => data,
        "ttl"     => ttl,
      }
      extra["priority"] = priority if priority
      resp = api_call("DNS-create-zone-record", extra)
      wrapper = resp["DNS-create-zone-recordresponse"]
      Record.new(
        id:       wrapper["record_id"].as_s,
        type:     type,
        host:     host,
        data:     data,
        ttl:      ttl,
        priority: priority
      )
    end

    # Update an existing DNS record.
    def update_record(zone_id : String, record_id : String, type : String,
                       host : String, data : String, ttl : String,
                       priority : String? = nil) : Record
      extra = {
        "zone_id"   => zone_id,
        "record_id" => record_id,
        "type"      => type,
        "host"      => host,
        "data"      => data,
        "ttl"       => ttl,
      }
      extra["priority"] = priority if priority
      api_call("DNS-update-zone-record", extra)
      # The API doesn't return useful data on update — re-fetch to confirm.
      list_records(zone_id).find { |r| r.id == record_id } ||
        raise "Record #{record_id} not found after update"
    end

    # Delete a DNS record.
    def delete_record(zone_id : String, record_id : String) : Nil
      api_call("DNS-delete-zone-record", {
        "zone_id"   => zone_id,
        "record_id" => record_id,
      })
    end

    # ─── Helpers ────────────────────────────────────────────────────────

    # Atlantic.net returns collections as a JSON object keyed by index
    # ("0", "1", ...) instead of an array. Handle both shapes: if it's
    # already an object, return it; if it's an array, convert to a map.
    private def extract_indexed_map(node : JSON::Any) : Hash(String, JSON::Any)
      case node.raw
      when Hash
        # Already indexed — just return as String-keyed Hash
        node.as_h.transform_keys(&.to_s)
      when Array
        # Sometimes the API returns an actual array — index it ourselves.
        node.as_a.each_with_index.to_h { |(item, i)| {i.to_s, item} }
      else
        raise "Expected object or array for indexed collection, got: #{node.raw.class}"
      end
    end
  end
end
