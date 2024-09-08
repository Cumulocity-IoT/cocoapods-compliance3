# # coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'cocoapods-compliance3/gem_version.rb'

Gem::Specification.new do |spec|
  spec.name          = 'cocoapods-compliance3'
  spec.version       = CocoapodsCompliance3::VERSION
  spec.authors       = ['Thomas Winkler']
  spec.email         = ['twi@softwareag.com']
  spec.summary       = 'A CocoaPods plugin to collect compliance information for TPSafe'
  spec.description   = 'This plugin collects compliance information such as license, website, download URL, and version for CocoaPods and SPM dependencies.'
  spec.homepage      = 'https://github.softwareag.com/IOTA/cocoapods-compliance3'
  spec.license       = 'MIT'

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  spec.add_development_dependency 'bundler', '~> 1.3'
  spec.add_development_dependency 'rake', '~> 13'
  spec.required_ruby_version = ">= 3.0"
end
