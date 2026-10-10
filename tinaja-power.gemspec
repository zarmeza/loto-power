# frozen_string_literal: true

require File.expand_path('lib/tinaja_power/version', __dir__)

Gem::Specification.new do |s|
  s.name = 'tinaja-power'
  s.version = TinajaPower::VERSION
  # exe/ rather than the default bin/, so the gemspec has to say so or RubyGems looks in
  # the wrong place and refuses to build.
  s.bindir = 'exe'
  s.executables << 'tinaja-power'
  s.summary = 'Records when the office loses power'
  s.description = 'Watches whether this laptop is on AC power and keeps a history of the ' \
                  'outages, marking the stretches when it was off and therefore saw nothing.'
  s.authors = ['Eleazar Meza']
  s.email = ['meza.eleazar@gmail.com']
  s.homepage = 'https://github.com/zarmeza/tinaja-power'
  s.license = 'MIT'
  s.required_ruby_version = '>= 4.0'
  s.files = Dir['README.md',
                'exe/tinaja-power',
                'lib/**/*.rb',
                'systemd/*',
                'tinaja-power.gemspec',
                'Gemfile',
                'Rakefile']
  # The only dependency. json, optparse, open3 and time are all stdlib, and the database
  # is a file on disk.
  s.add_dependency 'sqlite3', '~> 2.9'

  s.metadata['rubygems_mfa_required'] = 'true'
end
