require "test_helper"
require "json"
require "minitest/mock"
require "pathname"
require "rake"
require "tmpdir"
require "rails_mind/diagnostic"

# bin/rails rails_mind:doctor as an app runs it. Without what collection
# needs, it still prints its report, then names the missing setting and
# exits non-zero, as rails_mind:verify does.
class DoctorTaskTest < Minitest::Test
  def setup
    @previous_application = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load File.expand_path("../lib/tasks/rails_mind.rake", __dir__)
    @configuration = RailsMind.configuration
    @saved = [ @configuration.token, @configuration.endpoint ]
  end

  def teardown
    @configuration.token, @configuration.endpoint = @saved
    Rake.application = @previous_application
  end

  def test_without_the_key_it_names_RAILS_MIND_KEY_and_fails
    @configuration.token = nil
    output, errors, status = run_doctor

    assert_equal 1, status
    assert_includes errors, "RAILS_MIND_KEY is not set, so collection is off."
    report = JSON.parse(output)
    assert_equal false, report["credential_present"]
    assert_equal false, report["enabled"]
  end

  def test_a_blank_key_counts_as_missing
    @configuration.token = "  "
    _output, errors, status = run_doctor

    assert_equal 1, status
    assert_includes errors, "RAILS_MIND_KEY is not set"
  end

  def test_a_blank_endpoint_is_named_too
    @configuration.token = "test-only-key"
    @configuration.endpoint = " "
    output, errors, status = run_doctor

    assert_equal 1, status
    assert_includes errors, "The RailsMind endpoint is blank, so collection is off."
    refute_includes errors, "RAILS_MIND_KEY"
    refute_includes output + errors, "test-only-key"
  end

  def test_with_the_key_it_reports_and_succeeds_without_printing_the_key
    @configuration.token = "test-only-key"
    @configuration.endpoint = RailsMind::Configuration::DEFAULT_ENDPOINT
    output, errors, status = run_doctor

    assert_equal 0, status
    assert_empty errors
    assert_equal true, JSON.parse(output)["enabled"]
    refute_includes output, "test-only-key"
  end

  private
    def run_doctor
      status = 0
      output, errors = Dir.mktmpdir do |root|
        Rails.stub(:root, Pathname(root)) do
          RailsMind.stub(:stats, { enabled: false }) do
            capture_io do
              Rake::Task["rails_mind:doctor"].invoke
            rescue SystemExit => exit
              status = exit.status
            end
          end
        end
      end
      [ output, errors, status ]
    end
end
