require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))
runtime_version = File.read(File.join(__dir__, 'VERSION')).strip
properties_path = File.join(Pod::Config.instance.installation_root, 'Podfile.properties.json')
properties = File.exist?(properties_path) ? JSON.parse(File.read(properties_path)) : {}
media_adapter = properties.fetch('ios-voip-sdk.mediaAdapter', 'webrtc')
unless %w[webrtc livekit none].include?(media_adapter)
  raise 'IosVoipSDK: ios-voip-sdk.mediaAdapter must be webrtc, livekit, or none; regenerate the Expo iOS project.'
end
media_directory = { 'webrtc' => 'WebRTC', 'livekit' => 'LiveKit', 'none' => 'None' }.fetch(media_adapter)

# CocoaPods builds every subspec of a pod into one module, `IosVoipSDK`, so Swift code that uses the
# subspecs imports `IosVoipSDK` rather than the Swift package's product modules. Each call core
# subspec mirrors one product of Package.swift:
#
# | Subspec              | Swift package product    |
# |----------------------|--------------------------|
# | Core                 | VoIPCore                 |
# | LiveCommunicationKit | VoIPLiveCommunicationKit |
# | CallKit              | VoIPCallKit              |
# | PushKit              | VoIPPushKit              |
# | Simulator            | VoIPSimulator            |
# | Testing              | VoIPTesting              |
#
# An app depends on Core, exactly one of LiveCommunicationKit and CallKit, and usually PushKit.
# `pod 'IosVoipSDK'` without a subspec installs ExpoModule, the existing Expo module, as before.
# Don't combine ExpoModule with the call core subspecs: they would share one module and one
# calling framework provider.
Pod::Spec.new do |s|
  s.name = 'IosVoipSDK'
  s.version = runtime_version
  s.summary = package['description']
  s.homepage = 'https://github.com/relayphone/ios-voip-sdk'
  s.author = { 'Hamza Zia' => 'https://github.com/ziahamza' }
  s.license = { :type => 'UNLICENSED' }
  s.source = { :git => package['repository']['url'], :commit => '87a6125c18f9ec7018ac056c67baa06e9dbac07c' }
  s.platform = :ios, '26.0'
  s.swift_version = '6.0'
  s.static_framework = true
  s.header_dir = 'IosVoipSDK'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.default_subspecs = 'ExpoModule'

  # The existing Expo module and the ConversationClient it wraps.
  s.subspec 'ExpoModule' do |ss|
    ss.dependency 'IosVoipSDK/SimulatorRuntime'
    ss.dependency 'ExpoModulesCore'
    ss.frameworks = 'LiveCommunicationKit', 'AVFoundation', 'PushKit'
    media_sources = ['ExpoMedia/Shared/ExpoMediaSupport.swift', "ExpoMedia/#{media_directory}/**/*.{swift,h,m}"]
    if media_adapter != 'none'
      media_sources += ['ExpoMedia/Shared/VSMediaBinding.h', 'ExpoMedia/Shared/QueuedMediaAdapter.swift']
    end
    ss.source_files = ['Sources/VoIPPlatform/**/*.{h,m}', 'Sources/VoIPSDK/**/*.swift', 'Expo/apple/**/*.{swift,h}', *media_sources]
    public_headers = ['Sources/VoIPPlatform/include/*.h', 'Expo/apple/IosVoipSDK.h']
    public_headers << 'ExpoMedia/Shared/VSMediaBinding.h' if media_adapter != 'none'
    ss.public_header_files = public_headers
    if media_adapter == 'livekit'
      ss.dependency 'React-Core'
      ss.dependency 'livekit-react-native-webrtc', '= 150.1.0'
    end
  end

  # The simulator runtime's sources, shared by ExpoModule and Simulator. Depend on Simulator instead.
  s.subspec 'SimulatorRuntime' do |ss|
    ss.source_files = ['Sources/CKSimProtocol/**/*.swift', 'Sources/Engine/**/*.swift', 'Sources/Interposition/**/*.{h,m}']
    # The external DYLD loader is not part of the embedded SDK.
    ss.exclude_files = 'Sources/Interposition/CKLoader.m'
    ss.public_header_files = 'Sources/Interposition/include/CKRuntimeBridge.h'
    ss.private_header_files = 'Sources/Interposition/CKRuntimeSeam.h'
    ss.pod_target_xcconfig = {
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => '$(inherited) CKSIM_SDK_SOURCE',
      'GCC_PREPROCESSOR_DEFINITIONS' => "$(inherited) CKSIM_SDK_SOURCE=1 CKSIM_RUNTIME_VERSION=\\\"#{runtime_version}\\\""
    }
  end

  # The call's values, state machine and `VoIPClient`. Imports no calling framework.
  s.subspec 'Core' do |ss|
    ss.source_files = 'Sources/VoIPCore/**/*.swift'
  end

  # `LiveCommunicationKitAdapter`, the default calling framework adapter.
  s.subspec 'LiveCommunicationKit' do |ss|
    ss.dependency 'IosVoipSDK/Core'
    ss.source_files = 'Sources/VoIPLiveCommunicationKit/**/*.swift'
    ss.frameworks = 'LiveCommunicationKit', 'AVFAudio'
  end

  # `CallKitAdapter`, for apps that need CallKit's measured behaviour. Not for apps distributed in
  # China mainland.
  s.subspec 'CallKit' do |ss|
    ss.dependency 'IosVoipSDK/Core'
    ss.source_files = 'Sources/VoIPCallKit/**/*.swift'
    ss.frameworks = 'CallKit', 'AVFAudio'
  end

  # `PushKitSource`, with the Objective-C wrapper that completes each push once.
  s.subspec 'PushKit' do |ss|
    ss.dependency 'IosVoipSDK/Core'
    ss.source_files = ['Sources/VoIPPushKit/**/*.swift', 'Sources/VoIPPushDelivery/**/*.{h,m}']
    ss.public_header_files = 'Sources/VoIPPushDelivery/include/*.h'
    ss.frameworks = 'PushKit'
  end

  # `VoIPSimulator`, which presents calls in the iOS Simulator. Call `VoIPSimulator.activate()`
  # only in Debug builds: it does nothing in Release builds and on devices, where the runtime isn't
  # compiled in.
  s.subspec 'Simulator' do |ss|
    ss.dependency 'IosVoipSDK/SimulatorRuntime'
    ss.source_files = 'Sources/VoIPSimulator/**/*.swift'
  end

  # Fakes and a test clock that run `VoIPClient` without the system, for the app's tests.
  s.subspec 'Testing' do |ss|
    ss.dependency 'IosVoipSDK/Core'
    ss.source_files = 'Sources/VoIPTesting/**/*.swift'
  end
end
