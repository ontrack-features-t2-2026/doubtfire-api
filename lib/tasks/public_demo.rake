# frozen_string_literal: true

require Rails.root.join('lib/demo_data/public_demo_scenario')

namespace :db do
  desc 'Prepare only the guarded synthetic public-demo database; never reset existing records'
  task public_demo_prepare: :environment do
    result = DemoData::PublicDemoScenario.new(reference_time: Time.zone.now).prepare!
    puts "Public demo prepared: #{result.inspect}"
  end

  desc 'Verify the guarded synthetic public-demo database without changing records'
  task public_demo_verify: :environment do
    result = DemoData::PublicDemoScenario.new(reference_time: Time.zone.now).verify!
    puts "Public demo verified: #{result.inspect}"
  end
end
