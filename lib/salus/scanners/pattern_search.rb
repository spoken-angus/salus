require 'salus/scanners/base'

# Report any matches to a list of regexs provided by the config file.
# We will actually use sift, a superior grep like tool.
# Config file can provide:
#   - exclude_directories: Array of directories (GLOB) in the repo to exclude from the search.
#   - exclude_extensions: Array of file extensions to exclude from the search.
#   - include_extensions: Array of file extensions to scan exclusively.
#   The above can also be provided per-match, and will override the global values. Exclusions
#   take precedence over inclusions if they conflict.
#   - matches: Array[Hash]
#       regex:       <regex>   (required)      regex to match against.
#       forbidden:   <boolean> (default false) if true, a hit on this regex will fail the test.
#       required:    <boolean> (default false) if true, the absense of this pattern is a failure.
#       message:     <string>  (default '')    custom message to display among failure.

module Salus::Scanners
  class PatternSearch < Base
    def self.scanner_type
      Salus::ScannerTypes::SAST
    end

    def run
      global_exclude_directory_flags = flag_list('-g', @config['exclude_directory'])
      global_exclude_extension_flags = extension_flag('-g', @config['exclude_extension'], false)
      global_include_extension_flags = extension_flag('-g', @config['include_extension'], true)

      # For each pattern, keep a running history of failures, errors, and hits
      # These will be reported on at the end.
      failure_messages = []
      errors = []
      all_hits = []
      all_misses = []

      @config['matches']&.each do |match|
        # Sift has the following behavior:
        #   - if something found: return 0, report each hit to STDOUT - 1 per line.
        #   - if nothing found:   return 1, no STDOUT or STDERR
        #   - if error:           return 1, STDERR has the error
        #   - if panic:           return 2, STDERR has the error

        match_exclude_directory_flags = flag_list(
          '-g', match['exclude_directory']
        )
        match_exclude_extension_flags = extension_flag('-g', \
                                                       match['exclude_extension'], false)
        match_include_extension_flags = extension_flag('-g', match['include_extension'], true)

        # --exclude_filepaths can be specified at the global level and match level
        # if both are specified, they should be joined
        ex_paths = match['exclude_filepaths'] || @config['exclude_filepaths']
        exclude_filepath_pattern = filepath_pattern(ex_paths)

        command_array = [
          "rg",
          "\'#{match['regex']}\'",
          exclude_filepath_pattern,
          "-g",
          "\'\!salus.yaml\'",
          *(match_exclude_directory_flags || global_exclude_directory_flags),
          *(match_exclude_extension_flags || global_exclude_extension_flags),
          *(match_include_extension_flags || global_include_extension_flags)
        ].compact
        command_array = command_array.reject { |c| c.empty? }
        not_followed_within = match["not_followed_within"]
        command_array += ['--not-followed-within', not_followed_within] if not_followed_within
        files = match['files']
        files&.each do |file|
          command_array += ['-g', "\'#{file}\'"]
        end
        message = "command array is ", command_array
        puts message
        shell_return = run_shell(command_array)
        # Set defaults.
        match['forbidden'] ||= false
        match['required'] ||= false
        match['message'] ||= ''

        if shell_return.success? # hit
          if match['forbidden']
            failure_messages << "\nForbidden pattern \"#{match['regex']}\" was found " \
              "\n#{shell_return.stdout} - #{match['message']}"
          end

          hits = shell_return.stdout.encode(
            "utf-8",
            invalid: :replace,
            undef: :replace
          ).split("\n")

          hits.each do |hit|
            all_hits << {
              regex: match['regex'],
              forbidden: match['forbidden'],
              required: match['required'],
              msg: match['message'],
              hit: hit
            }
          end

        elsif [1, 2].include?(shell_return.status)
          if shell_return.stderr.empty?
            # If there were no hits, but the pattern was required add an error message.
            if match['required']
              failure_messages << "Required pattern \"#{match['regex']}\" was not found " \
                "- #{match['message']}"
              all_misses << {
                regex: match['regex'],
                forbidden: match['forbidden'],
                required: match['required'],
                msg: match['message']
              }
            end
          else
            errors << { status: shell_return.status, stderr: shell_return.stderr }
          end
        else
          raise UnhandledExitStatusError,
                "Unknown exit status #{shell_return.status} from ripgrep "\
                  "(grep alternative).\n" \
                  "STDOUT: #{shell_return.stdout}\n" \
                  "STDERR: #{shell_return.stderr}"
        end
      end

      report_info(:hits, all_hits)
      report_info(:misses, all_misses)
      errors.each { |error| report_error('Call to ripgrep failed', error) }

      if failure_messages.empty?
        report_success
      else
        report_failure
        failure_messages.each { |message| log(message) }
      end
    end

    def should_run?
      true # we will always run this on the provided folder
    end

    def version
      shell_return = run_shell('rg --version')
      # stdout looks like "ripgrep 13.0.0 -SIMD -AVX (compiled) +SIMD +AVX (runtime)"
      shell_return.stdout&.split&.dig(1)
    end

    def self.supported_languages
      ['*']
    end

    private

    def extension_flag(flag, file_extensions, include)
      if file_extensions.nil? || flag.nil?
        nil
      elsif file_extensions.empty? || flag.empty?
        ""
      else
        flag << ' '
        joined = file_extensions.join(",")
          .prepend("*.{")
          .concat("}\'")
        if include
          joined.prepend("\'")
        else
          joined.prepend("\'\!")
        end
        
        flag << joined
      end
    end

    # returns nil if list is nil
    def flag_list(flag, list)
      list&.map do |value|
        "#{flag} \'\!#{value}\'"
      end
    end

    # filepaths need to be joined into a sift path pattern
    # Ex. [file1, file2, file3] need to be joined into
    #       ^file1$|^file2$|^file3$
    def filepath_pattern(filepaths)
      return "" if filepaths.nil?

      joined = filepaths.join(",")
      joined.prepend("-g \'\!{")
      joined.concat("}\'")
    end
  end
end
