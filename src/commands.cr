require "option_parser"
require "json"
require "./client"
require "./types"

module AtlanticDNS
  module Commands
    # Single source of truth: read the version from shard.yml at compile time.
    VERSION = {{ read_file("#{__DIR__}/../shard.yml").lines.find(&.starts_with?("version:")).split(":")[1].strip }}

    # ─── instances ──────────────────────────────────────────────────────

    def self.instances(client : Client, name : String?, json : Bool) : Nil
      list = client.list_instances
      list = list.select { |i| i.name == name } if name
      if list.empty?
        puts(name ? "No instance named '#{name}' found" : "No instances found") unless json
        return
      end
      if json
        puts JSON.build { |j|
          j.array { list.each { |i| instance_to_json(j, i) } }
        }
      else
        list.each { |i| puts "#{i.name}  #{i.ip}  #{i.status}  #{i.plan}  #{i.location}  (#{i.id})" }
      end
    end

    # ─── zones ──────────────────────────────────────────────────────────

    def self.zones(client : Client, json : Bool) : Nil
      zones = client.list_zones
      if zones.empty?
        puts "No zones found" unless json
      elsif json
        output = JSON.build { |j|
          j.array {
            zones.each { |z| zone_to_json(j, z) }
          }
        }
        puts output
      else
        zones.each { |z| puts "#{z.name}  (#{z.id})" }
      end
    end

    # ─── zone-add ────────────────────────────────────────────────────────

    def self.zone_add(client : Client, zone_name : String, json : Bool) : Nil
      zone = client.create_zone(zone_name)
      output_record("Created zone", zone, json)
    end

    # ─── zone-delete ────────────────────────────────────────────────────

    def self.zone_delete(client : Client, zone_name : String) : Nil
      zone_id = client.resolve_zone_id(zone_name)
      client.delete_zone(zone_id)
      puts "Deleted zone '#{zone_name}'"
    end

    # ─── list ────────────────────────────────────────────────────────────

    def self.list(client : Client, zone_name : String, json : Bool) : Nil
      zone_id = client.resolve_zone_id(zone_name)
      records = client.list_records(zone_id)
      if json
        output = JSON.build { |j|
          j.array {
            records.each { |r| record_to_json(j, r) }
          }
        }
        puts output
      else
        records.each { |r| print_record(r) }
      end
    end

    # ─── add ─────────────────────────────────────────────────────────────

    def self.add(client : Client, zone_name : String, type : String,
                 host : String, data : String, ttl : String,
                 priority : String?, json : Bool) : Nil
      zone_id = client.resolve_zone_id(zone_name)
      record = client.create_record(zone_id, type, api_name(host, zone_name), data, ttl, priority)
      output_record("Created", record, json)
    end

    # ─── delete ──────────────────────────────────────────────────────────

    def self.delete_by_id(client : Client, zone_name : String,
                           record_id : String, json : Bool) : Nil
      zone_id = client.resolve_zone_id(zone_name)
      client.delete_record(zone_id, record_id)
      output_message("Deleted record #{record_id}", json)
    end

    def self.delete_by_match(client : Client, zone_name : String,
                             type : String, host : String, json : Bool) : Nil
      zone_id = client.resolve_zone_id(zone_name)
      records = client.list_records(zone_id).select { |r|
        r.type.downcase == type.downcase && r.host == host
      }
      if records.empty?
        STDERR.puts "No matching record found: type=#{type} host=#{host}"
        exit 1
      end
      records.each { |r| client.delete_record(zone_id, r.id) }
      count = records.size
      output_message("Deleted #{count} record(s) matching type=#{type} host=#{host}", json)
    end

    # ─── set-for-instance ────────────────────────────────────────────────

    def self.set_for_instance(client : Client, zone_name : String,
                               instance_name : String, ttl : String, json : Bool) : Nil
      instance = client.list_instances.find { |i| i.name.downcase == instance_name.downcase }
      unless instance
        STDERR.puts "Error: no instance named '#{instance_name}' found"
        exit 1
      end
      host = "#{instance.name.downcase}.#{zone_name}"
      set(client, zone_name: zone_name, type: "A", host: host,
          data: instance.ip, ttl: ttl, priority: nil, json: json)
    end

    # ─── set (upsert) ────────────────────────────────────────────────────

    def self.set(client : Client, zone_name : String, type : String,
                 host : String, data : String, ttl : String,
                 priority : String?, json : Bool) : Nil
      zone_id = client.resolve_zone_id(zone_name)
      existing = client.list_records(zone_id).find { |r|
        r.type.downcase == type.downcase && r.host == host
      }

      record = if existing
        if existing.data == data && existing.ttl == ttl && existing.priority == priority
          output_record("Unchanged", existing, json)
          return
        end
        client.update_record(zone_id, existing.id, type, api_name(host, zone_name), data, ttl, priority)
      else
        client.create_record(zone_id, type, api_name(host, zone_name), data, ttl, priority)
      end

      output_record("Set", record, json)
    end

    # ─── Helpers ────────────────────────────────────────────────────────

    private def self.print_record(r : Record) : Nil
      parts = ["#{r.type} #{r.host} → #{r.data}  ttl=#{r.ttl}"]
      parts << "priority=#{r.priority}" if r.priority
      parts << "  (#{r.id})"
      puts parts.join(" ")
    end

    private def self.output_record(prefix : String, r : Record, json : Bool) : Nil
      if json
        puts JSON.build { |j| record_to_json(j, r) }
      else
        puts "#{prefix}: #{r.type} #{r.host} → #{r.data}  ttl=#{r.ttl}  (#{r.id})"
      end
    end

    private def self.output_record(prefix : String, z : Zone, json : Bool) : Nil
      if json
        puts JSON.build { |j| zone_to_json(j, z) }
      else
        puts "#{prefix}: #{z.name}  (#{z.id})"
      end
    end

    private def self.output_message(msg : String, json : Bool) : Nil
      if json
        puts JSON.build { |j| j.string(msg) }
      else
        puts msg
      end
    end

    # Strip the zone suffix so the API doesn't double-append it.
    # "test.staging.dirless.com" + zone "staging.dirless.com" → "test"
    # "@" or the bare zone name → "@"
    private def self.api_name(host : String, zone_name : String) : String
      return "@" if host == "@" || host == zone_name
      suffix = ".#{zone_name}"
      host.ends_with?(suffix) ? host[0, host.size - suffix.size] : host
    end

    private def self.instance_to_json(j : JSON::Builder, i : Instance) : Nil
      j.object do
        j.field("id", i.id)
        j.field("name", i.name)
        j.field("ip", i.ip)
        j.field("status", i.status)
        j.field("location", i.location)
        j.field("plan", i.plan)
      end
    end

    private def self.zone_to_json(j : JSON::Builder, z : Zone) : Nil
      j.object do
        j.field("id", z.id)
        j.field("name", z.name)
      end
    end

    private def self.record_to_json(j : JSON::Builder, r : Record) : Nil
      j.object do
        j.field("id", r.id)
        j.field("type", r.type)
        j.field("host", r.host)
        j.field("data", r.data)
        j.field("ttl", r.ttl)
        j.field("priority", r.priority) if r.priority
      end
    end
  end
end
