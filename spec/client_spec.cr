require "./spec_helper"

# Every request to the API includes unique timestamp/guid/signature query params,
# so we can't stub the exact URL. Use a regex matching the base URL + any query.
BASE_URL_RX = /https:\/\/example\.com\/\?/

def stub_api(body : String)
  WebMock.stub(:get, BASE_URL_RX)
    .to_return(body: body, headers: {"Content-Type" => "application/json"})
end

describe AtlanticDNS::Client do
  # ─── Signing ────────────────────────────────────────────────────────

  describe "HMAC signing" do
    it "produces a deterministic HMAC-SHA256 signature" do
      ts   = 1700000000
      guid = "abc123"
      msg  = "#{ts}#{guid}"

      expected_sig = Base64.strict_encode(
        OpenSSL::HMAC.digest(:sha256, "testsecret".to_slice, msg.to_slice)
      )

      # SHA-256 HMAC = 32 bytes → Base64 = 44 chars
      expected_sig.size.should eq(44)

      # Same input → same output (deterministic)
      sig2 = Base64.strict_encode(
        OpenSSL::HMAC.digest(:sha256, "testsecret".to_slice, msg.to_slice)
      )
      sig2.should eq(expected_sig)
    end

    it "changes signature when timestamp changes" do
      sig_a = Base64.strict_encode(
        OpenSSL::HMAC.digest(:sha256, "secret".to_slice, "100foo".to_slice)
      )
      sig_b = Base64.strict_encode(
        OpenSSL::HMAC.digest(:sha256, "secret".to_slice, "200foo".to_slice)
      )
      sig_a.should_not eq(sig_b)
    end
  end

  # ─── Zone listing (index-keyed map shape) ───────────────────────────

  describe "#list_zones" do
    it "parses DNSSet array response" do
      client = AtlanticDNS::Client.new(
        access_key: "k", private_key: "s",
        base_url: "https://example.com/"
      )

      stub_api({
        "dns-list-zonesresponse" => {
          "DNSSet" => [
            {"zone_id" => "101", "domain_name" => "example.com"},
            {"zone_id" => "202", "domain_name" => "staging.example.com"},
          ],
        },
      }.to_json)

      zones = client.list_zones
      zones.size.should eq(2)
      zones[0].id.should eq("101")
      zones[0].name.should eq("example.com")
      zones[1].id.should eq("202")
      zones[1].name.should eq("staging.example.com")
    end

    it "returns empty array when DNSSet is absent" do
      client = AtlanticDNS::Client.new(
        access_key: "k", private_key: "s",
        base_url: "https://example.com/"
      )

      stub_api({
        "dns-list-zonesresponse" => {"requestid" => "abc"},
      }.to_json)

      client.list_zones.should be_empty
    end
  end

  # ─── Record listing ─────────────────────────────────────────────────

  describe "#list_records" do
    it "parses records from an index-keyed map" do
      client = AtlanticDNS::Client.new(
        access_key: "k", private_key: "s",
        base_url: "https://example.com/"
      )

      stub_api({
        "dns-list-zone-recordsresponse" => {
          "DNSSet" => [
            {
              "record_id" => "501", "type" => "A", "name" => "@",
              "content" => "1.2.3.4", "ttl" => "3600", "prio" => "0",
            },
            {
              "record_id" => "502", "type" => "CNAME", "name" => "www",
              "content" => "example.com", "ttl" => "7200", "prio" => "0",
            },
          ],
        },
      }.to_json)

      records = client.list_records("101")
      records.size.should eq(2)
      records[0].id.should eq("501")
      records[0].type.should eq("A")
      records[0].host.should eq("@")
      records[0].data.should eq("1.2.3.4")
      records[0].ttl.should eq("3600")
      records[1].type.should eq("CNAME")
      records[1].host.should eq("www")
    end
  end

  # ─── API error handling ─────────────────────────────────────────────

  describe "API errors" do
    it "raises with raw body on non-JSON response (e.g. CloudFlare 522)" do
      client = AtlanticDNS::Client.new(
        access_key: "k", private_key: "s",
        base_url: "https://example.com/"
      )

      WebMock.stub(:get, BASE_URL_RX)
        .to_return(body: "error code: 522", headers: {"Content-Type" => "text/html"})

      expect_raises(Exception, /non-JSON response/) do
        client.list_zones
      end
    end

    it "raises APIError on error response" do
      client = AtlanticDNS::Client.new(
        access_key: "k", private_key: "s",
        base_url: "https://example.com/"
      )

      stub_api({
        "error" => {"code" => "AuthFailure", "message" => "Invalid access key"},
      }.to_json)

      expect_raises(AtlanticDNS::APIError, "AuthFailure") do
        client.list_zones
      end
    end
  end

  # ─── Record CRUD ─────────────────────────────────────────────────────

  describe "#create_record" do
    it "returns the record after re-fetching by type+host+data" do
      client = AtlanticDNS::Client.new(
        access_key: "k", private_key: "s",
        base_url: "https://example.com/"
      )

      WebMock.stub(:get, /Action=DNS-create-zone-record/)
        .to_return(body: {
          "dns-create-zone-recordresponse" => {
            "DNSSet" => {"status" => "success", "message" => "A record was saved successfully"},
          },
        }.to_json)

      WebMock.stub(:get, /Action=DNS-list-zone-records/)
        .to_return(body: {
          "dns-list-zone-recordsresponse" => {
            "DNSSet" => [
              {"record_id" => "601", "type" => "A", "name" => "portal",
               "content" => "1.2.3.4", "ttl" => "3600", "prio" => "0"},
            ],
          },
        }.to_json)

      record = client.create_record("101", "A", "portal", "example.com", "1.2.3.4", "3600")
      record.id.should eq("601")
      record.type.should eq("A")
      record.host.should eq("portal")
      record.data.should eq("1.2.3.4")
    end
  end

  describe "#delete_record" do
    it "succeeds on 200 response" do
      client = AtlanticDNS::Client.new(
        access_key: "k", private_key: "s",
        base_url: "https://example.com/"
      )

      stub_api(%({"DNS-delete-zone-recordresponse": {}}))

      # Should not raise
      client.delete_record("101", "501")
    end
  end

  # ─── resolve_zone_id ────────────────────────────────────────────────

  describe "#create_zone" do
    it "parses create-zone response" do
      client = AtlanticDNS::Client.new(
        access_key: "k", private_key: "s",
        base_url: "https://example.com/"
      )

      stub_api({
        "dns-create-zoneresponse" => {"zone_id" => "303"},
      }.to_json)

      zone = client.create_zone("newzone.example.com")
      zone.id.should eq("303")
      zone.name.should eq("newzone.example.com")
    end
  end

  describe "#delete_zone" do
    it "succeeds on 200 response" do
      client = AtlanticDNS::Client.new(
        access_key: "k", private_key: "s",
        base_url: "https://example.com/"
      )

      stub_api(%({"DNS-delete-zoneresponse": {}}))

      client.delete_zone("303")
    end
  end

  describe "#resolve_zone_id" do
    it "returns the zone ID for a matching name" do
      client = AtlanticDNS::Client.new(
        access_key: "k", private_key: "s",
        base_url: "https://example.com/"
      )

      stub_api({
        "dns-list-zonesresponse" => {
          "DNSSet" => [
            {"zone_id" => "101", "domain_name" => "example.com"},
            {"zone_id" => "202", "domain_name" => "staging.example.com"},
          ],
        },
      }.to_json)

      client.resolve_zone_id("staging.example.com").should eq("202")
    end

    it "raises when zone not found" do
      client = AtlanticDNS::Client.new(
        access_key: "k", private_key: "s",
        base_url: "https://example.com/"
      )

      stub_api({
        "dns-list-zonesresponse" => {
          "DNSSet" => [
            {"zone_id" => "101", "domain_name" => "example.com"},
          ],
        },
      }.to_json)

      expect_raises(Exception, "Zone 'nonexistent.com' not found") do
        client.resolve_zone_id("nonexistent.com")
      end
    end
  end
end

describe AtlanticDNS::KeepassXC do
  describe ".lookup" do
    it "reads multiple attributes from a mock keepassxc-cli command" do
      mock_script = "/tmp/fake_keepassxc.sh"
      begin
        # Echo all -a argument values, one per line
        File.write(mock_script, "#!/bin/bash\nwhile [[ $# -gt 0 ]]; do if [[ \"$1\" == \"-a\" ]]; then echo \"$2\"; fi; shift; done\n")
        File.chmod(mock_script, 0o755)

        # The mock doesn't need stdin — pipe an empty password
        ENV["KEEPASS_MASTER"] = "test"
        result = AtlanticDNS::KeepassXC.lookup("/dev/null", "test-entry",
          ["UserName", "Password"], command: mock_script)
        result.should eq(["UserName", "Password"])
      ensure
        ENV.delete("KEEPASS_MASTER")
        File.delete?(mock_script)
      end
    end

    it "raises on non-zero exit" do
      mock_script = "/tmp/fake_keepassxc_fail.sh"
      begin
        File.write(mock_script, "#!/bin/bash\necho \"Error: entry not found\" >&2\nexit 1\n")
        File.chmod(mock_script, 0o755)

        ENV["KEEPASS_MASTER"] = "test"
        expect_raises(Exception, "failed") do
          AtlanticDNS::KeepassXC.lookup("/dev/null", "nope", ["UserName"],
            command: mock_script)
        end
      ensure
        ENV.delete("KEEPASS_MASTER")
        File.delete?(mock_script)
      end
    end
  end
end
