module AtlanticDNS
  # A DNS zone on Atlantic.net.
  struct Zone
    getter id : String
    getter name : String

    def initialize(@id : String, @name : String)
    end
  end

  # A DNS record within a zone.
  struct Record
    getter id : String
    getter type : String
    getter host : String
    getter data : String
    getter ttl : String
    getter priority : String?

    def initialize(@id : String, @type : String, @host : String, @data : String,
                   @ttl : String, @priority : String? = nil)
    end
  end

  # A compute instance on Atlantic.net.
  struct Instance
    getter id : String
    getter name : String
    getter ip : String
    getter status : String
    getter location : String
    getter plan : String

    def initialize(@id : String, @name : String, @ip : String,
                   @status : String, @location : String, @plan : String)
    end
  end

  # Structured error returned by the Atlantic.net API.
  class APIError < Exception
    getter code : String

    def initialize(@code : String, message : String)
      super("Atlantic.net API error #{@code}: #{message}")
    end
  end
end
