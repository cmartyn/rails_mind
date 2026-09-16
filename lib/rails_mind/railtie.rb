require_relative "integrations/rails"

module RailsMind
  class Railtie < Rails::Railtie
    initializer "rails_mind.request_context" do |app|
      app.middleware.insert_after ActionDispatch::RequestId, Integrations::RequestContext
    end

    config.after_initialize do
      Integrations::RailsNotifications.install!
      Rails.error.subscribe(Integrations::ErrorSubscriber.new)
      ActiveSupport.on_load(:active_job) do
        include Integrations::JobContext unless included_modules.include?(Integrations::JobContext)
      end
      at_exit { RailsMind.shutdown }
    end

    rake_tasks { load File.expand_path("../tasks/rails_mind.rake", __dir__) }
  end
end
