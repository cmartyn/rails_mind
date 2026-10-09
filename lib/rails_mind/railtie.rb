require_relative "integrations/rails"
require_relative "integrations/action_mailer"

module RailsMind
  class Railtie < Rails::Railtie
    initializer "rails_mind.request_context" do |app|
      app.middleware.insert_after ActionDispatch::RequestId, Integrations::RequestContext
    end

    config.after_initialize do
      Integrations::RailsNotifications.install!
      Integrations::MailerNotifications.install!
      Rails.error.subscribe(Integrations::ErrorSubscriber.new)
      ActiveSupport.on_load(:active_job) do
        include Integrations::JobContext unless included_modules.include?(Integrations::JobContext)
      end
      ActiveSupport.on_load(:action_mailer) do
        include Integrations::MailerCallbacks unless included_modules.include?(Integrations::MailerCallbacks)
        unless ActionMailer::MessageDelivery.ancestors.include?(Integrations::MailerDeliveryContext)
          ActionMailer::MessageDelivery.prepend(Integrations::MailerDeliveryContext)
        end
        Mail::Message.prepend(Integrations::ForcedMailerTransport) unless Mail::Message.ancestors.include?(Integrations::ForcedMailerTransport)
      end
      at_exit { RailsMind.shutdown }
    end

    rake_tasks { load File.expand_path("../tasks/rails_mind.rake", __dir__) }
  end
end
