require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))
properties_path = File.join(Pod::Config.instance.installation_root, 'Podfile.properties.json')
properties = File.exist?(properties_path) ? JSON.parse(File.read(properties_path)) : {}
media = properties.fetch('@relayphone/ios-voip-sdk.mediaAdapter', 'webrtc')
raise 'mediaAdapter must be webrtc or none' unless %w[webrtc none].include?(media)
enabled = ->(name) { properties.fetch("@relayphone/ios-voip-sdk.#{name}", 'false') == 'true' }
simulator = enabled.call('simulator')
conditions = []
conditions << 'VOIP_CONVERSATIONS_WEBRTC' if media == 'webrtc'
conditions << 'VOIP_CONVERSATIONS_NOTIFICATIONS' if enabled.call('callNotifications')
conditions << 'VOIP_CONVERSATIONS_LIVE_ACTIVITY' if enabled.call('callPreviewActivities')
conditions << 'VOIP_CONVERSATIONS_FOCUS' if enabled.call('focusFilter')

# Both checkout installs and npm distributions use the same synchronized sources.
sdk = 'Vendor'
manifest_path = File.join(__dir__, sdk, 'sources.json')
raise 'SDK sources are missing; run npm run sync:sources in the Expo package' unless File.file?(manifest_path)
manifest = JSON.parse(File.read(manifest_path))
runtime = %w[CKSimProtocol Engine Interposition VoIPSimulator]
runtime_files = runtime.flat_map do |target|
  Dir.glob(File.join(__dir__, sdk, target, '**', '*.{swift,m}')).map { |path| File.basename(path) }
end.join(' ')

specification = Pod::Spec.new do |s|
  s.name = 'VoIPConversations'
  s.version = package['version']
  s.summary = package['description']
  s.homepage = package['homepage']
  s.author = package['author']
  s.license = package['license']
  s.source = { :git => 'https://github.com/relayphone/ios-voip-sdk.git', :tag => "v#{s.version}" }
  s.platform = :ios, '26.0'
  s.swift_version = '6.0'
  s.static_framework = true
  s.default_subspecs = 'Module'
  s.script_phase = {
    :name => 'Verify bundled SDK sources',
    :execution_position => :before_compile,
    :script => <<~SCRIPT
      set -e
      if [ -f "$PODS_ROOT/../.xcode.env" ]; then . "$PODS_ROOT/../.xcode.env"; fi
      if [ -f "$PODS_ROOT/../.xcode.env.local" ]; then . "$PODS_ROOT/../.xcode.env.local"; fi
      "${NODE_BINARY:-node}" "$PODS_TARGET_SRCROOT/../build-scripts/prepare-package.mjs" --check
    SCRIPT
  }
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => "$(inherited) #{conditions.join(' ')}",
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphonesimulator*][config=Debug]' => "$(inherited) DEBUG #{conditions.join(' ')} #{simulator ? 'CKSIM_SDK_SOURCE VOIP_CONVERSATIONS_SIMULATOR' : ''}",
    'SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY' => 'YES',
    'SWIFT_UPCOMING_FEATURE_INTERNAL_IMPORTS_BY_DEFAULT' => 'YES',
    'SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY' => 'YES',
    'GCC_PREPROCESSOR_DEFINITIONS[sdk=iphonesimulator*][config=Debug]' => "$(inherited) DEBUG=1 CKSIM_SDK_SOURCE=1 CKSIM_RUNTIME_VERSION=\\\"#{s.version}\\\" VOIP_CONVERSATIONS_SIMULATOR=#{simulator ? 1 : 0}",
    'EXCLUDED_SOURCE_FILE_NAMES' => runtime_files,
    'EXCLUDED_SOURCE_FILE_NAMES[sdk=iphonesimulator*][config=Debug]' => '',
    'SWIFT_INCLUDE_PATHS' => '$(PODS_TARGET_SRCROOT)/WebRTCHeaders',
  }

  s.subspec 'Module' do |ss|
    ss.source_files = ['*.swift', 'Mapping/**/*.swift', 'VoIPConversations.h']
    ss.public_header_files = 'VoIPConversations.h'
    ss.preserve_paths = 'WebRTCHeaders/**'
    ss.dependency 'ExpoModulesCore'
    ss.dependency 'VoIPConversations/Core'
    ss.dependency 'VoIPConversations/Audio'
    ss.dependency 'VoIPConversations/LiveCommunicationKit'
    ss.dependency 'VoIPConversations/PushKit'
    ss.dependency 'VoIPConversations/Simulator' if simulator
    ss.dependency 'VoIPConversations/LiveActivity' if enabled.call('callPreviewActivities')
    ss.dependency 'VoIPConversations/Focus' if enabled.call('focusFilter')
    if enabled.call('callNotifications')
      ss.dependency 'VoIPConversations/Notifications'
      ss.dependency 'ExpoNotifications'
    end
  end

  s.subspec 'Core' do |ss|
    ss.source_files = "#{sdk}/VoIPCore/**/*.swift"
  end

  s.subspec 'MediaTesting' do |ss|
    ss.source_files = "#{sdk}/VoIPMediaTesting/**/*.swift"
    ss.dependency 'LiveKitClient', '= 2.19.0'
    ss.frameworks = 'AVFAudio'
  end

  s.subspec 'Audio' do |ss|
    ss.dependency 'VoIPConversations/Core'
    ss.source_files = "#{sdk}/VoIPAudio/**/*.swift"
    ss.frameworks = 'AVFAudio'
  end

  s.subspec 'LiveCommunicationKit' do |ss|
    ss.dependency 'VoIPConversations/Core'
    ss.source_files = "#{sdk}/VoIPLiveCommunicationKit/**/*.swift"
    ss.frameworks = 'LiveCommunicationKit', 'AVFAudio'
  end

  s.subspec 'PushKit' do |ss|
    ss.dependency 'VoIPConversations/Core'
    ss.source_files = ["#{sdk}/VoIPPushKit/**/*.swift", "#{sdk}/VoIPPushDelivery/**/*.{h,m}"]
    ss.public_header_files = "#{sdk}/VoIPPushDelivery/include/*.h"
    ss.frameworks = 'PushKit', 'UIKit'
  end

  s.subspec 'Notifications' do |ss|
    ss.dependency 'VoIPConversations/Core'
    ss.source_files = "#{sdk}/VoIPNotifications/**/*.swift"
    ss.frameworks = 'UserNotifications', 'Intents', 'UIKit'
  end

  s.subspec 'LiveActivity' do |ss|
    ss.dependency 'VoIPConversations/Core'
    ss.source_files = "#{sdk}/VoIPLiveActivity/**/*.swift"
    ss.frameworks = 'ActivityKit', 'AppIntents', 'SwiftUI', 'UIKit', 'WidgetKit'
  end

  s.subspec 'Focus' do |ss|
    ss.source_files = "#{sdk}/VoIPFocus/**/*.swift"
    ss.frameworks = 'AppIntents'
  end

  s.subspec 'Simulator' do |ss|
    ss.source_files = runtime.map { |target| "#{sdk}/#{target}/**/*.{swift,h,m}" }
    ss.exclude_files = "#{sdk}/Interposition/CKLoader.m"
    ss.private_header_files = "#{sdk}/Interposition/**/*.h"
  end
end

# Count the files CocoaPods actually discovered, rather than trusting filesystem globs.
{
  'Core' => %w[VoIPCore],
  'Audio' => %w[VoIPAudio],
  'LiveCommunicationKit' => %w[VoIPLiveCommunicationKit],
  'PushKit' => %w[VoIPPushKit VoIPPushDelivery],
  'Notifications' => %w[VoIPNotifications],
  'LiveActivity' => %w[VoIPLiveActivity],
  'Focus' => %w[VoIPFocus],
  'Simulator' => runtime,
}.each do |name, targets|
  expected = manifest.fetch('files').keys.count { |path| targets.include?(path.split('/').first) }
  consumer = specification.subspec_by_name("VoIPConversations/#{name}").consumer(:ios)
  actual = Pod::Sandbox::FileAccessor.new(Pathname(__dir__), consumer).source_files.length
  unless expected.positive? && actual == expected
    raise "CocoaPods discovered #{actual} SDK files for #{name}; expected #{expected}. Run npm run sync:sources."
  end
end

specification
