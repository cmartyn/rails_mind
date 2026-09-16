namespace :rails_mind do
  desc "Send one installation check; confirm its processing in RailsMind Setup"
  task verify: :environment do
    require "rails_mind/installation_check"
    result = RailsMind::InstallationCheck.new.run
    puts JSON.pretty_generate(result)
    exit 1 unless result[:success]
  end

  desc "Inspect dependencies and report the non-destructive integration plan"
  task doctor: :environment do
    require "rails_mind/diagnostic"
    puts JSON.pretty_generate(RailsMind::Diagnostic.new(root: Rails.root).report.merge(collector: RailsMind.stats))
  end
end
