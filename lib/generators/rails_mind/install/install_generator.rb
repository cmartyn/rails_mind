require "rails/generators"
require "rails_mind/diagnostic"

module RailsMind
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)
      class_option :plan, type: :boolean, default: false, desc: "Print the integration plan without writing files"
      class_option :browser, type: :boolean, default: false, desc: "Copy the optional Ahoy/Turbo adapter without enabling it"

      def inspect_application
        say JSON.pretty_generate(Diagnostic.new(root: destination_root).report)
      end

      def add_initializer
        return if options[:plan]
        path = "config/initializers/rails_mind.rb"
        if File.exist?(File.join(destination_root, path))
          say_status :skip, "#{path} already exists", :yellow
        else
          template "initializer.rb.tt", path
        end
      end

      def add_browser_adapter
        return if options[:plan] || !options[:browser]
        path = "app/javascript/rails_mind.js"
        if File.exist?(File.join(destination_root, path))
          say_status :skip, "#{path} already exists", :yellow
        else
          copy_file File.expand_path("../../../../javascript/rails_mind.js", __dir__), path
        end
        say "Pin rails_mind in importmap.rb and start it with your existing Ahoy instance. See docs/sdk.md."
      end
    end
  end
end
