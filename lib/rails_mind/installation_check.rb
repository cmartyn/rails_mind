require_relative "../rails_mind"

module RailsMind
  class InstallationCheck
    def initialize(config = RailsMind.configuration, transport: nil)
      @config, @transport = config, transport
    end

    def run(timeout: 10)
      return result(false, "Set RAILS_MIND_KEY in your app's environment, then try again. The endpoint defaults to https://railsmind.com; if you override it, provide a nonblank endpoint.") unless @config.enabled?
      @config.validate!
      # A dedicated collector gives this command an exact result without flushing
      # or changing the running application's collector or its existing counters.
      collector = Collector.new(@config, transport: @transport || Transport.new(@config), autostart: false)
      client = Client.new(@config, collector: collector)
      id = SecureRandom.uuid
      unless client.emit(:check, "RailsMind installation check", id: id, properties: { sdk_version: VERSION })
        return result(false, "The SDK did not enqueue the check. Review before_send and collector settings.", id)
      end
      unless collector.flush(timeout: timeout)
        return result(false, "Delivery was not confirmed before the deadline. Check outbound HTTPS access and the endpoint, then look for this ID in Setup before retrying.", id)
      end
      if collector.stats[:delivered] == 1 && collector.stats[:dropped].zero?
        result(true, "Check delivered. Open RailsMind Setup for your app and environment and match this ID. Installation is verified when it says Check processed.", id)
      else
        result(false, "Delivery failed. Check the endpoint, active ingest key, daily quota, and server support for installation checks. Run rails_mind:doctor for local settings.", id)
      end
    ensure
      collector&.shutdown(timeout: 0.05)
    end

    private

    def result(success, message, id = nil)
      { success: success, check_id: id, message: message }
    end
  end
end
