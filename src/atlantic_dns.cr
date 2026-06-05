require "option_parser"
require "./commands"

module AtlanticDNS
  def self.run(args : Array(String)) : Nil
    json      = false
    debug     = false
    keepass_db = nil

    if args.empty?
      puts usage
      exit 0
    end

    # Handle --help/-h before subcommand dispatch
    if args[0] == "--help" || args[0] == "-h"
      puts usage
      exit 0
    end

    subcommand = args.shift

    case subcommand
    when "instances"
      name = nil
      opts = OptionParser.new do |p|
        p.banner = "Usage: atlantic-dns instances [--name NAME]"
        p.on("--name NAME", "Filter by instance name (vm_description)") { |v| name = v }
        p.on("--keepass-db PATH", "KeepassXC database path") { |v| keepass_db = v }
        p.on("--json", "JSON output") { json = true }
        p.on("--debug", "Log signed URL (creds masked)") { debug = true }
        p.on("-h", "--help", "Show help") { puts p; exit 0 }
      end
      opts.parse(args)
      client = make_client(debug: debug, keepass_db: keepass_db)
      Commands.instances(client, name: name, json: json)
    when "zones", "zone-list"
      opts = OptionParser.new do |p|
        p.banner = "Usage: atlantic-dns zones"
        p.on("--keepass-db PATH", "KeepassXC database path (looks up 'atlanticnet' entry)") { |v| keepass_db = v }
        p.on("--json", "JSON output") { json = true }
        p.on("--debug", "Log signed URL (creds masked)") { debug = true }
        p.on("-h", "--help", "Show help") { puts p; exit 0 }
      end
      opts.parse(args)
      unless args.empty?
        STDERR.puts "Warning: 'zones' takes no arguments (got: #{args.join(", ")}). Did you mean 'list --zone ...'?"
      end
      client = make_client(debug: debug, keepass_db: keepass_db)
      Commands.zones(client, json: json)
    when "zone-add"
      opts = OptionParser.new do |p|
        p.banner = "Usage: atlantic-dns zone-add <zone>"
        p.on("--keepass-db PATH", "KeepassXC database path") { |v| keepass_db = v }
        p.on("--json", "JSON output") { json = true }
        p.on("--debug", "Log signed URL (creds masked)") { debug = true }
        p.on("-h", "--help", "Show help") { puts p; exit 0 }
      end
      opts.parse(args)
      # Remaining non-flag args are the zone name
      positional = args.reject { |a| a.starts_with?("-") }
      zone_name = positional.first?
      require_arg(zone_name, "zone name")
      client = make_client(debug: debug, keepass_db: keepass_db)
      Commands.zone_add(client, zone_name: zone_name.not_nil!, json: json)
    when "zone-delete"
      opts = OptionParser.new do |p|
        p.banner = "Usage: atlantic-dns zone-delete <zone>"
        p.on("--keepass-db PATH", "KeepassXC database path") { |v| keepass_db = v }
        p.on("--debug", "Log signed URL (creds masked)") { debug = true }
        p.on("-h", "--help", "Show help") { puts p; exit 0 }
      end
      opts.parse(args)
      positional = args.reject { |a| a.starts_with?("-") }
      zone_name = positional.first?
      require_arg(zone_name, "zone name")
      client = make_client(debug: debug, keepass_db: keepass_db)
      Commands.zone_delete(client, zone_name: zone_name.not_nil!)
    when "list"
      zone_name = nil
      opts = OptionParser.new do |p|
        p.banner = "Usage: atlantic-dns list --zone <zone>"
        p.on("--zone ZONE", "Zone name (e.g. staging.dirless.com)") { |v| zone_name = v }
        p.on("--keepass-db PATH", "KeepassXC database path") { |v| keepass_db = v }
        p.on("--json", "JSON output") { json = true }
        p.on("--debug", "Log signed URL (creds masked)") { debug = true }
        p.on("-h", "--help", "Show help") { puts p; exit 0 }
      end
      opts.parse(args)
      require_arg(zone_name, "--zone")
      client = make_client(debug: debug, keepass_db: keepass_db)
      Commands.list(client, zone_name: zone_name.not_nil!, json: json)
    when "add"
      zone_name = type = host = data = ttl = priority = nil
      opts = OptionParser.new do |p|
        p.banner = "Usage: atlantic-dns add --zone Z --type TYPE --host HOST --data DATA [--ttl 3600] [--priority N]"
        p.on("--zone ZONE", "Zone name") { |v| zone_name = v }
        p.on("--type TYPE", "Record type (A, AAAA, CNAME, MX, TXT, etc.)") { |v| type = v }
        p.on("--host HOST", "Subdomain (@ = apex, * = wildcard)") { |v| host = v }
        p.on("--data DATA", "Record value") { |v| data = v }
        p.on("--ttl TTL", "TTL in seconds") { |v| ttl = v }
        p.on("--priority N", "Priority (MX / SRV)") { |v| priority = v }
        p.on("--keepass-db PATH", "KeepassXC database path") { |v| keepass_db = v }
        p.on("--json", "JSON output") { json = true }
        p.on("--debug", "Log signed URL (creds masked)") { debug = true }
        p.on("-h", "--help", "Show help") { puts p; exit 0 }
      end
      opts.parse(args)
      require_arg(zone_name, "--zone")
      require_arg(type, "--type")
      require_arg(host, "--host")
      require_arg(data, "--data")
      ttl      ||= "3600"
      client = make_client(debug: debug, keepass_db: keepass_db)
      Commands.add(client, zone_name: zone_name.not_nil!, type: type.not_nil!,
                   host: host.not_nil!, data: data.not_nil!,
                   ttl: ttl.not_nil!, priority: priority, json: json)
    when "delete"
      zone_name = record_id = type = host = nil
      opts = OptionParser.new do |p|
        p.banner = "Usage: atlantic-dns delete --zone Z --id RECORD_ID\n" \
                   "       atlantic-dns delete --zone Z --type TYPE --host HOST"
        p.on("--zone ZONE", "Zone name") { |v| zone_name = v }
        p.on("--id ID", "Record ID (direct delete)") { |v| record_id = v }
        p.on("--type TYPE", "Record type (for match-and-delete)") { |v| type = v }
        p.on("--host HOST", "Subdomain (for match-and-delete)") { |v| host = v }
        p.on("--keepass-db PATH", "KeepassXC database path") { |v| keepass_db = v }
        p.on("--json", "JSON output") { json = true }
        p.on("--debug", "Log signed URL (creds masked)") { debug = true }
        p.on("-h", "--help", "Show help") { puts p; exit 0 }
      end
      opts.parse(args)
      require_arg(zone_name, "--zone")
      client = make_client(debug: debug, keepass_db: keepass_db)
      if record_id
        Commands.delete_by_id(client, zone_name: zone_name.not_nil!, record_id: record_id.not_nil!, json: json)
      elsif type && host
        Commands.delete_by_match(client, zone_name: zone_name.not_nil!, type: type.not_nil!, host: host.not_nil!, json: json)
      else
        STDERR.puts "Error: specify --id or both --type and --host"
        STDERR.puts opts
        exit 1
      end
    when "set"
      zone_name = type = host = data = ttl = priority = nil
      opts = OptionParser.new do |p|
        p.banner = "Usage: atlantic-dns set --zone Z --type TYPE --host HOST --data DATA [--ttl 3600] [--priority N]"
        p.on("--zone ZONE", "Zone name") { |v| zone_name = v }
        p.on("--type TYPE", "Record type (A, AAAA, CNAME, MX, TXT, etc.)") { |v| type = v }
        p.on("--host HOST", "Subdomain (@ = apex, * = wildcard)") { |v| host = v }
        p.on("--data DATA", "Record value") { |v| data = v }
        p.on("--ttl TTL", "TTL in seconds") { |v| ttl = v }
        p.on("--priority N", "Priority (MX / SRV)") { |v| priority = v }
        p.on("--keepass-db PATH", "KeepassXC database path") { |v| keepass_db = v }
        p.on("--json", "JSON output") { json = true }
        p.on("--debug", "Log signed URL (creds masked)") { debug = true }
        p.on("-h", "--help", "Show help") { puts p; exit 0 }
      end
      opts.parse(args)
      require_arg(zone_name, "--zone")
      require_arg(type, "--type")
      require_arg(host, "--host")
      require_arg(data, "--data")
      ttl      ||= "3600"
      client = make_client(debug: debug, keepass_db: keepass_db)
      Commands.set(client, zone_name: zone_name.not_nil!, type: type.not_nil!,
                   host: host.not_nil!, data: data.not_nil!,
                   ttl: ttl.not_nil!, priority: priority, json: json)
    when "version", "--version", "-v"
      puts Commands::VERSION
    when "help"
      puts usage
    else
      STDERR.puts "Unknown command: #{subcommand}"
      STDERR.puts usage
      exit 1
    end
  end

  private def self.make_client(debug : Bool, keepass_db : String?) : Client
    access_key  = ENV["ATLANTICNET_ACCESS_KEY"]?
    private_key = ENV["ATLANTICNET_PRIVATE_KEY"]?

    # Fall back to KeepassXC if env vars aren't set and --keepass-db was given.
    if (!access_key || !private_key) && keepass_db
      begin
        keys = KeepassXC.fetch_keys(keepass_db)
        access_key  ||= keys[:access_key]
        private_key ||= keys[:private_key]
      rescue ex
        STDERR.puts "Error: #{ex.message}"
        exit 1
      end
    end

    unless access_key && private_key
      if keepass_db
        STDERR.puts "Error: could not load credentials from KeepassXC"
      else
        STDERR.puts "Error: set ATLANTICNET_ACCESS_KEY and ATLANTICNET_PRIVATE_KEY," \
                    " or use --keepass-db <path>"
      end
      exit 1
    end

    Client.new(access_key: access_key, private_key: private_key, debug: debug)
  end

  # Require a non-nil value; exits with a message if nil.
  private def self.require_arg(value : String?, flag : String) : Nil
    unless value
      STDERR.puts "Error: #{flag} is required"
      exit
    end
  end

  private def self.usage : String
    <<-USAGE
    atlantic-dns #{Commands::VERSION}

    Usage:
      atlantic-dns <command> [options]

    Commands:
      instances          List compute instances (--name to filter)
      zones              List all DNS zones
      zone-add           Create a new DNS zone
      zone-delete        Delete a DNS zone
      list               List records in a zone
      add                Add a DNS record
      delete             Delete a DNS record (by ID or type+host match)
      set                Upsert a DNS record (idempotent)
      version            Print version

    Credentials (pick one):
      ATLANTICNET_ACCESS_KEY / ATLANTICNET_PRIVATE_KEY    Environment variables
      --keepass-db <path>                                  KeepassXC database (entry: 'atlanticnet')

    Flags (all commands):
      --json              JSON output
      --debug             Log signed URL (creds masked)
      -h, --help          Show help

    Run 'atlantic-dns <command> -h' for command-specific options.
    USAGE
  end
end

begin
  AtlanticDNS.run(ARGV)
rescue ex : Exception
  STDERR.puts "Error: #{ex.message}"
  exit 1
end
