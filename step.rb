require 'optparse'
require 'pathname'
require 'timeout'

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

def build_project!(project_path)
  xbuild = '/Library/Frameworks/Mono.framework/Versions/Current/bin/xbuild'
  output_dir = File.join('bin', 'Release')

  params = ["#{xbuild}"]
  params << "\"#{project_path}\""
  params << '/t:PackageForAndroid'
  params << '/p:Configuration=Release'
  params << "/p:OutputPath=\"#{output_dir}/\""

  # Build project
  puts "#{params.join(' ')}"
  system("#{params.join(' ')}")
  fail_with_message('Build failed') unless $?.success?

  # Get the build path
  project_directory = File.dirname(project_path)
  File.join(project_directory, output_dir)
end

def build_test_project!(project_path)
  xbuild = '/Library/Frameworks/Mono.framework/Versions/Current/bin/xbuild'
  output_dir = File.join('bin', 'Release')

  params = ["#{xbuild}"]
  params << "\"#{project_path}\""
  params << '/t:Build'
  params << '/p:Configuration=Release'
  params << "/p:OutputPath=\"#{output_dir}/\""

  # Build project
  puts "#{params.join(' ')}"
  system("#{params.join(' ')}")
  fail_with_message('Build failed') unless $?.success?

  # Get the build path
  project_directory = File.dirname(project_path)
  File.join(project_directory, output_dir)
end


def clean_project!(project_path)
  xbuild = '/Library/Frameworks/Mono.framework/Versions/Current/bin/xbuild'

  params = ["\"#{xbuild}\""]
  params << "\"#{project_path}\""
  params << '/t:Clean'
  params << "/p:Configuration='Release'"

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
  mono = '/Library/Frameworks/Mono.framework/Versions/Current/bin/mono'
  out = `#{mono} #{nunit_console_path} #{dll_path}`
  puts out
  fail_with_message("#{mono} #{nunit_console_path} #{dll_path} -- failed") unless $?.success?

  regex = 'Tests run: (?<total>\d*), Errors: (?<errors>\d*), Failures: (?<failures>\d*), Inconclusive: (?<inconclusives>\d*), Time: (?<time>\S*) seconds\n  Not run: (?<not_run>\d*), Invalid: (?<invalid>\d*), Ignored: (?<ignored>\d*), Skipped: (?<skipped>\d*)'
  match = out.match(regex)
  unless match.nil?
    _total, errors, failures, _inconclusives, _time, _not_run, _invalid, _ignored, _skipped = match.captures
    fail_with_message("#{mono} #{nunit_console_path} #{dll_path} -- failed") unless errors.to_i == 0 && failures.to_i == 0
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
  clean_build: true,
  emulator_serial: nil,
  nunit_path: nil
}

parser = OptionParser.new do|opts|
  opts.banner = 'Usage: step.rb [options]'
  opts.on('-s', '--project path', 'Project path') { |s| options[:project] = s unless s.to_s == '' }
  opts.on('-t', '--test project', 'Test project') { |t| options[:test_project] = t unless t.to_s == '' }
  opts.on('-i', '--clean build', 'Clean build') { |i| options[:clean_build] = false if i.to_s == 'no' }
  opts.on('-n', '--nunit path', 'NUnit path') { |n| options[:nunit_path] = n unless n.to_s == '' }
  opts.on('-e', '--emulator serial', 'Emulator serial') { |e| options[:emulator_serial] = e unless e.to_s == '' }
  opts.on('-h', '--help', 'Displays Help') do
    exit
  end
end
parser.parse!

fail_with_message('project not specified') unless options[:project]
fail_with_message('test_project not specified') unless options[:test_project]
fail_with_message('emulator_serial not specified') unless options[:emulator_serial]
fail_with_message('nunit_console_path not specified') unless options[:nunit_path]

#
# Print configs
puts
puts '========== Configs =========='
puts " * project: #{options[:project]}"
puts " * test_project: #{options[:test_project]}"
puts " * clean_build: #{options[:clean_build]}"
puts " * emulator_serial: #{options[:emulator_serial]}"

#
# Restoring nuget packages
puts ''
puts "==> Restoring nuget packages for project: #{options[:project]}"
solutions = get_related_solutions(options[:project])
if solutions && solutions.count > 0
  solutions.each do |solution|
    puts "(i) solution: #{solution}"
    puts "/Library/Frameworks/Mono.framework/Versions/Current/bin/nuget restore #{solution}"
    system("/Library/Frameworks/Mono.framework/Versions/Current/bin/nuget restore #{solution}")
    error_with_message('Failed to restore nuget package') unless $?.success?
  end
else
  puts "No solution found for project: #{options[:project]}, terminating nuget restore..."
end

puts ''
puts "==> Restoring nuget packages for project: #{options[:test_project]}"
solutions = get_related_solutions(options[:test_project])
if solutions && solutions.count > 0
  solutions.each do |solution|
    puts "(i) solution: #{solution}"
    puts "/Library/Frameworks/Mono.framework/Versions/Current/bin/nuget restore #{solution}"
    system("/Library/Frameworks/Mono.framework/Versions/Current/bin/nuget restore #{solution}")
    error_with_message('Failed to restore nuget package') unless $?.success?
  end
else
  puts "No solution found for project: #{options[:test_project]}, terminating nuget restore..."
end

if options[:clean_build]
  #
  # Cleaning the project
  puts
  puts "==> Cleaning project: #{options[:project]}"
  clean_project!(options[:project])

  puts
  puts "==> Cleaning project: #{options[:test_project]}"
  clean_project!(options[:test_project])
end

#
# Build project
puts
puts "==> Building project: #{options[:project]}"
build_path = build_project!(options[:project])
fail_with_message('Failed to locate build path') unless build_path

apk_path = export_apk(build_path)
fail_with_message('failed to get .apk path') unless apk_path
puts "  (i) .app path: #{apk_path}"

#
# Build UITest
puts
puts "==> Building project: #{options[:test_project]}"
test_build_path = build_test_project!(options[:test_project])
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

# Set output envs
work_dir = ENV['BITRISE_SOURCE_DIR']
result_log = File.join(work_dir, 'TestResult.xml')
system('envman add --key BITRISE_XAMARIN_TEST_RESULT --value succeeded') if work_dir
system("envman add --key BITRISE_XAMARIN_TEST_FULL_RESULTS_TEXT --value #{result_log}") if work_dir
