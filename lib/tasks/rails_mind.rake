namespace :rails_mind do
  desc "Send one installation check; confirm its processing in RailsMind Setup"
  task verify: :environment do
    require "rails_mind/installation_check"
    result = RailsMind::InstallationCheck.new.run
    puts JSON.pretty_generate(result)
    exit 1 unless result[:success]
  end

  desc "Inspect dependencies and report the non-destructive integration plan; fails while collection is off"
  task doctor: :environment do
    require "rails_mind/diagnostic"
    diagnostic = RailsMind::Diagnostic.new(root: Rails.root)
    puts JSON.pretty_generate(diagnostic.report.merge(collector: RailsMind.stats))
    problems = diagnostic.problems
    unless problems.empty?
      warn problems
      exit 1
    end
  end
end
