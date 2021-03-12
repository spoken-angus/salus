require 'json'
require 'json-schema'
require_relative './base_sarif'

Dir.entries(File.expand_path('./', __dir__)).sort.each do |filename|
  next unless /\_sarif.rb\z/.match?(filename) && !filename.eql?('base_sarif.rb')

  require_relative filename
end

module Sarif
  # Class for generating sarif reports
  class SarifReport
    class SarifInvalidFormatError < StandardError; end

    SARIF_VERSION = "2.1.0".freeze

    SARIF_SCHEMA = "https://docs.oasis-open.org/sarif/sarif/v#{SARIF_VERSION}/csprd01/schemas/"\
    "sarif-schema-#{SARIF_VERSION}".freeze

    def initialize(scan_reports, config = {})
      @scan_reports = scan_reports
      @config = config
    end

    # Builds Sarif Report. Raises an SarifInvalidFormatError if generated SARIF report is invalid
    #
    # @return [JSON]
    def to_sarif
      sarif_report = {
        "version" => SARIF_VERSION,
        "$schema" => SARIF_SCHEMA,
        "runs" => []
      }
      # for each scanner report, run the appropriate converter
      @scan_reports.each { |scan_report| sarif_report["runs"] << converter(scan_report[0]) }
      report = JSON.pretty_generate(sarif_report)
      path = File.expand_path('schema/sarif-schema.json', __dir__)
      schema = JSON.parse(File.read(path))

      if JSON::Validator.validate(schema, report)
        report
      else
        errors = JSON::Validator.fully_validate(schema, report)
        raise SarifInvalidFormatError, "Incorrect Sarif Output: #{errors}" end
    end

    # Converts a ScanReport to a sarif report for the given scanner
    #
    # @params sarif_report [Salus::ScanReport]
    # @return
    def converter(scan_report)
      adapter = "Sarif::#{scan_report.scanner_name}Sarif"
      begin
        converter = Object.const_get(adapter).new(scan_report)
        converter.build_runs_object(true)
      rescue NameError
        converter = BaseSarif.new(scan_report, @config)
        converter.build_runs_object(false)
      end
    end
  end
end
