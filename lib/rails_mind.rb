require_relative "rails_mind/version"
require_relative "rails_mind/configuration"
require_relative "rails_mind/context"
require_relative "rails_mind/redactor"
require_relative "rails_mind/transport"
require_relative "rails_mind/collector"
require_relative "rails_mind/client"

module RailsMind
  class << self
    attr_writer :client

    def configuration = @configuration ||= Configuration.new
    def client = @client ||= Client.new(configuration)

    def configure
      yield configuration
      @client&.collector&.shutdown
      @client = Client.new(configuration)
    end

    def track(name, properties = {}, id: nil, occurred_at: nil, **additional_properties)
      client.emit(:event, name, properties: properties.merge(additional_properties), id: id, occurred_at: occurred_at)
    end
    def capture_exception(error, **options) = client.capture_exception(error, **options)
    def with_context(**context, &block) = Context.with(context, &block)
    def identify(**identity) = Context.identify(**identity)
    def flush(timeout: configuration.shutdown_timeout) = client.collector&.flush(timeout: timeout)
    def shutdown = @client&.collector&.shutdown
    def stats = client.collector&.stats || { enabled: false }
  end
end

require_relative "rails_mind/railtie" if defined?(Rails::Railtie)
