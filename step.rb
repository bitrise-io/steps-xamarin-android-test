require 'optparse'
require 'pathname'
require 'timeout'

@mono = '/Library/Frameworks/Mono.framework/Versions/Current/bin/mono'
@nuget = '/Library/Frameworks/Mono.framework/Versions/Current/bin/nuget'

# -----------------------
# --- functions
# -----------------------

def fail_with_message(message)
  `envman add --key BITRISE_XAMARIN_TEST_RESULT --value failed`

  puts "\e[31m#{message}\e[0m"
  exit(1)
end

def error_with_message(message)
  puts "\e[31m#{message}\e[0m"
end

def to_bool(value)
  return true if value == true || value =~ (/^(true|t|yes|y|1)$/i)
  return false if value == false || value.nil? || value == '' || value =~ (/^(false|f|no|n|0)$/i)
  fail_with_message("Invalid value for Boolean: \"#{value}\"")
end

def get_related_solutions(project_path)
  project_name = File.basename(project_path)
  project_dir = File.dirname(project_path)
  root_dir = File.dirname(project_dir)
  solutions = Dir[File.join(root_dir, '/**/*.sln')]
  return [] unless solutions

  related_solutions = []
  solutions.each do |solution|
    File.readlines(solution).join("\n").scan(/Project\(\"[^\"]*\"\)\s*=\s*\"[^\"]*\",\s*\"([^\"]*.csproj)\"/).each do |match|
      a_project = match[0].strip.gsub(/\\/, '/')
      a_project_name = File.basename(a_project)

      related_solutions << solution if a_project_name == project_name
    end
  end

  return related_solutions
end

def build_project!(project_path, configuration, platform)
  output_dir = File.join('bin', platform, configuration)

  params = ['xbuild']
  params << "\"#{project_path}\""
  params << '/t:PackageForAndroid'
  params << "/p:Configuration=\"#{configuration}\""
  params << "/p:Platform=\"#{platform}\""
  params << "/p:OutputPath=\"#{output_dir}/\""

  # Build project
  puts "#{params.join(' ')}"
  system("#{params.join(' ')}")
  fail_with_message('Build failed') unless $?.success?

  # Get the build path
  project_directory = File.dirname(project_path)
  File.join(project_directory, output_dir)
end

def build_test_project!(project_path, configuration, platform)
  output_dir = File.join('bin', platform, configuration)

  params = ['xbuild']
  params << "\"#{project_path}\""
  params << '/t:Build'
  params << "/p:Configuration=#{configuration}"
  params << "/p:Platform=\"#{platform}\""
  params << "/p:OutputPath=\"#{output_dir}/\""

  # Build project
  puts "#{params.join(' ')}"
  system("#{params.join(' ')}")
  fail_with_message('Build failed') unless $?.success?

  # Get the build path
  project_directory = File.dirname(project_path)
  File.join(project_directory, output_dir)
end

def clean_project!(project_path, configuration, platform)
  params = ['xbuild']
  params << "\"#{project_path}\""
  params << '/t:Clean'
  params << "/p:Configuration=#{configuration}"
  params << "/p:Platform=\"#{platform}\""

  # clean project
  puts "#{params.join(' ')}"
  system("#{params.join(' ')}")
  fail_with_message('Clean failed') unless $?.success?
end

def export_apk(build_path)
  apk_path = Dir[File.join(build_path, '/**/*.apk')].first
  return nil unless apk_path

  full_path = Pathname.new(apk_path).realpath.to_s
  return nil unless full_path
  return nil unless File.exist? full_path
  full_path
end

def export_dll(test_build_path)
  dll_path = Dir[File.join(test_build_path, '/**/*.dll')].first
  return nil unless dll_path

  full_path = Pathname.new(dll_path).realpath.to_s
  return nil unless full_path
  return nil unless File.exist? full_path
  full_path
end

def run_unit_test!(nunit_console_path, dll_path)
  # nunit-console.exe Test.dll /xml=Test-results.xml /out=Test-output.txt

  nunit_path = ENV['NUNIT_PATH']
  fail_with_message('No NUNIT_PATH environment specified') unless nunit_path

  nunit_console_path = File.join(nunit_path, 'nunit3-console.exe')
  system("#{@mono} #{nunit_console_path} #{dll_path}")
  unless $?.success?
    work_dir = ENV['BITRISE_SOURCE_DIR']
    result_log = File.join(work_dir, 'TestResult.xml')
    file = File.open(result_log)
    contents = file.read
    file.close
    puts
    puts "result: #{contents}"
    puts
    fail_with_message("#{@mono} #{nunit_console_path} #{dll_path} -- failed")
  end
end

# -----------------------
# --- main
# -----------------------

#
# Input validation
options = {
  project: nil,
  test_project: nil,
  configuration: nil,
  platform: nil,
  clean_build: true,
  emulator_serial: nil
}

parser = OptionParser.new do|opts|
  opts.banner = 'Usage: step.rb [options]'
  opts.on('-s', '--project path', 'Project path') { |s| options[:project] = s unless s.to_s == '' }
  opts.on('-t', '--test project', 'Test project') { |t| options[:test_project] = t unless t.to_s == '' }
  opts.on('-c', '--configuration config', 'Configuration') { |c| options[:configuration] = c unless c.to_s == '' }
  opts.on('-p', '--platform platform', 'Platform') { |p| options[:platform] = p unless p.to_s == '' }
  opts.on('-i', '--clean build', 'Clean build') { |i| options[:clean_build] = false if to_bool(i) == false }
  opts.on('-e', '--emulator serial', 'Emulator serial') { |e| options[:emulator_serial] = e unless e.to_s == '' }
  opts.on('-h', '--help', 'Displays Help') do
    exit
  end
end
parser.parse!

fail_with_message('No project file found') unless options[:project] && File.exist?(options[:project])
fail_with_message('No test_project file found') unless options[:test_project] && File.exist?(options[:test_project])
fail_with_message('configuration not specified') unless options[:configuration]
fail_with_message('platform not specified') unless options[:platform]
fail_with_message('emulator_serial not specified') unless options[:emulator_serial]

#
# Print configs
puts
puts '========== Configs =========='
puts " * project: #{options[:project]}"
puts " * test_project: #{options[:test_project]}"
puts " * configuration: #{options[:configuration]}"
puts " * platform: #{options[:platform]}"
puts " * clean_build: #{options[:clean_build]}"
puts " * emulator_serial: #{options[:emulator_serial]}"

#
# Restoring nuget packages
puts ''
puts '==> Restoring nuget packages'
project_solutions = get_related_solutions(options[:project])
puts "No solution found for project: #{options[:project]}, terminating nuget restore..." if project_solutions.empty?

test_project_solutions = get_related_solutions(options[:test_project])
puts "No solution found for project: #{options[:test_project]}, terminating nuget restore..." if test_project_solutions.empty?

solutions = project_solutions | test_project_solutions
solutions.each do |solution|
  puts "(i) solution: #{solution}"
  puts "#{@nuget} restore #{solution}"
  system("#{@nuget} restore #{solution}")
  error_with_message('Failed to restore nuget package') unless $?.success?
end

if options[:clean_build]
  #
  # Cleaning the project
  puts
  puts "==> Cleaning project: #{options[:project]}"
  clean_project!(options[:project], options[:configuration], options[:platform])

  puts
  puts "==> Cleaning project: #{options[:test_project]}"
  clean_project!(options[:test_project], options[:configuration], options[:platform])
end

#
# Build project
puts
puts "==> Building project: #{options[:project]}"
build_path = build_project!(options[:project], options[:configuration], options[:platform])
fail_with_message('Failed to locate build path') unless build_path

apk_path = export_apk(build_path)
fail_with_message('failed to get .apk path') unless apk_path
puts "  (i) .app path: #{apk_path}"

#
# Build UITest
puts
puts "==> Building project: #{options[:test_project]}"
test_build_path = build_test_project!(options[:test_project], options[:configuration], options[:platform])
fail_with_message('failed to get test build path') unless test_build_path

dll_path = export_dll(test_build_path)
fail_with_message('failed to get .dll path') unless dll_path
puts "  (i) .dll path: #{dll_path}"

#
# Run unit test
puts
puts '=> run unit test'

ENV['ANDROID_EMULATOR_SERIAL'] = options[:emulator_serial]
ENV['ANDROID_APK_PATH'] = apk_path

run_unit_test!(options[:nunit_path], dll_path)

#
# Set output envs
work_dir = ENV['BITRISE_SOURCE_DIR']
result_log = File.join(work_dir, 'TestResult.xml')

puts
puts '(i) The result is: succeeded'
system('envman add --key BITRISE_XAMARIN_TEST_RESULT --value succeeded') if work_dir

puts
puts "(i) The test log is available at: #{result_log}"
system("envman add --key BITRISE_XAMARIN_TEST_FULL_RESULTS_TEXT --value #{result_log}") if work_dir
