require 'optparse'
require 'pathname'
require 'timeout'
require 'nokogiri'

require_relative 'xamarin-builder/builder'
require_relative 'xamarin-builder/common_constants'

# -----------------------
# --- Constants
# -----------------------

@mono = '/Library/Frameworks/Mono.framework/Versions/Current/bin/mono'

@work_dir = ENV['BITRISE_SOURCE_DIR']
@result_log_path = File.join(@work_dir, 'TestResult.xml')

# -----------------------
# --- Functions
# -----------------------

def puts_info(message)
  puts
  puts "\e[34m#{message}\e[0m"
end

def puts_details(message)
  puts "  #{message}"
end

def puts_done(message)
  puts "  \e[32m#{message}\e[0m"
end

def puts_warning(message)
  puts "\e[33m#{message}\e[0m"
end

def puts_error(message)
  puts "\e[31m#{message}\e[0m"
end

def puts_fail(message)
  system('envman add --key BITRISE_XAMARIN_TEST_RESULT --value failed')

  puts "\e[31m#{message}\e[0m"
  exit(1)
end

# -----------------------
# --- Main
# -----------------------

#
# Parse options
options = {
  project: nil,
  configuration: nil,
  platform: nil,
  clean_build: true,
  test_to_run: nil,
  emulator_serial: nil
}

parser = OptionParser.new do |opts|
  opts.banner = 'Usage: step.rb [options]'
  opts.on('-s', '--project path', 'Project path') { |s| options[:project] = s unless s.to_s == '' }
  opts.on('-c', '--configuration config', 'Configuration') { |c| options[:configuration] = c unless c.to_s == '' }
  opts.on('-p', '--platform platform', 'Platform') { |p| options[:platform] = p unless p.to_s == '' }
  opts.on('-t', '--test test', 'Test to run') { |t| options[:test_to_run] = t unless t.to_s == '' }
  opts.on('-e', '--emulator serial', 'Emulator serial') { |e| options[:emulator_serial] = e unless e.to_s == '' }
  opts.on('-h', '--help', 'Displays Help') do
    exit
  end
end
parser.parse!

#
# Print options
puts_info 'Configs:'
puts_details "* project: #{options[:project]}"
puts_details "* configuration: #{options[:configuration]}"
puts_details "* platform: #{options[:platform]}"
puts_details "* test_to_run: #{options[:test_to_run]}"
puts_details "* emulator_serial: #{options[:emulator_serial]}"

#
# Validate options
puts_fail('No project file found') unless options[:project] && File.exist?(options[:project])
puts_fail('configuration not specified') unless options[:configuration]
puts_fail('platform not specified') unless options[:platform]
puts_fail('emulator_serial not specified') unless options[:emulator_serial]

#
# Main
nunit_path = ENV['NUNIT_2_PATH']
puts_fail('No NUNIT_2_PATH environment specified') unless nunit_path

nunit_console_path = File.join(nunit_path, 'nunit-console.exe')
puts_fail('nunit-console.exe not found') unless File.exist?(nunit_console_path)

builder = Builder.new(options[:project], options[:configuration], options[:platform], 'android')
begin
  builder.build
  builder.build_test
rescue => ex
  puts_error(ex.inspect.to_s)
  puts_error('--- Stack trace: ---')
  puts_error(ex.backtrace.to_s)
  exit(1)
end

output = builder.generated_files
puts_fail 'No output generated' if output.nil? || output.empty?

any_uitest_built = false

output.each do |_, project_output|
  api = project_output[:api]
  next unless api.eql? Api::ANDROID

  apk = project_output[:apk]
  uitests = project_output[:uitests]
  next if apk.nil? || uitests.nil?

  ENV['ANDROID_APK_PATH'] = File.expand_path(apk)

  uitests.each do |dll_path|
    any_uitest_built = true

    puts_info "Running UITest agains #{apk}"

    params = [
      @mono,
      nunit_console_path,
      dll_path
    ]
    params << "run=\"#{options[:test_to_run]}\"" unless options[:test_to_run].nil?

    command = params.join(' ')

    puts command
    success = system(command)

    #
    # Process output
    result_log = ''
    if File.exist? @result_log_path
      file = File.open(@result_log_path)
      result_log = file.read
      file.close

      system("envman add --key BITRISE_XAMARIN_TEST_FULL_RESULTS_TEXT --value \"#{result_log}\"") if result_log.to_s != ''
      puts_details "Logs are available at path: #{@result_log_path}"
      puts
    end

    next if success

    doc = Nokogiri::XML(result_log)
    failed_tests = doc.xpath('//test-case[@result="Failed"]')

    if !failed_tests.empty?
      puts_info 'Parsed TestResults.xml'

      failed_tests.each do |failed_test|
        puts
        puts_error failed_test['name'].to_s
        puts_error failed_test.xpath('./failure/message').text.to_s

        puts 'Stack trace:'
        puts failed_test.xpath('./failure/stack-trace').text
        puts
      end
    else
      puts
      puts result_log
      puts
    end

    puts_fail('UITest execution failed')
  end

  # Set output envs
  system('envman add --key BITRISE_XAMARIN_TEST_RESULT --value succeeded')
  puts_done 'UITests finished with success'

  system("envman add --key BITRISE_XAMARIN_TEST_FULL_RESULTS_TEXT --value #{@result_log_path}") if @result_log_path
  puts_details "Logs are available at: #{@result_log_path}"
end

unless any_uitest_built
  puts "generated_files: #{output}"
  puts_fail 'No apk or test dll found in outputs'
end
