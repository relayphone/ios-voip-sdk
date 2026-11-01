runtime_version = File.read(File.join(__dir__, 'VERSION')).strip

# CocoaPods builds every subspec of a pod into one module, `IosVoipSDK`, so Swift code that uses the
# subspecs imports `IosVoipSDK` rather than the Swift package's product modules. Each subspec except
# SimulatorRuntime mirrors one product of Package.swift:
#
# | Subspec              | Swift package product    |
# |----------------------|--------------------------|
# | Core                 | VoIPCore                 |
# | Audio                | VoIPAudio                |
# | Focus                | VoIPFocus                |
# | LiveActivity         | VoIPLiveActivity         |
# | LiveCommunicationKit | VoIPLiveCommunicationKit |
# | PushKit              | VoIPPushKit              |
# | Notifications        | VoIPNotifications        |
# | Simulator            | VoIPSimulator            |
# | Testing              | VoIPTesting              |
#
# An app depends on Core and LiveCommunicationKit, and usually PushKit and Audio.
# `pod 'IosVoipSDK'` without a subspec installs Core, LiveCommunicationKit and PushKit.
Pod::Spec.new do |s|
  s.name = 'IosVoipSDK'
  s.version = runtime_version
  s.summary = 'Calls for iOS apps through LiveCommunicationKit, with PushKit and the iOS Simulator.'
  s.homepage = 'https://github.com/relayphone/ios-voip-sdk'
  s.author = { 'Hamza Zia' => 'https://github.com/ziahamza' }
  s.license = { :type => 'UNLICENSED' }
  s.source = { :git => 'https://github.com/relayphone/ios-voip-sdk.git', :commit => '87a6125c18f9ec7018ac056c67baa06e9dbac07c' }
  s.platform = :ios, '26.0'
  s.swift_version = '6.0'
  s.static_framework = true
  s.header_dir = 'IosVoipSDK'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.default_subspecs = 'Core', 'LiveCommunicationKit', 'PushKit'

  # The simulator runtime's sources, which Simulator presents. Depend on Simulator instead.
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

  # `AudioSessionAdapter`, which configures `AVAudioSession` for calls, reports its interruptions and
  # lists its audio routes.
  s.subspec 'Audio' do |ss|
    ss.dependency 'IosVoipSDK/Core'
    ss.source_files = 'Sources/VoIPAudio/**/*.swift'
    ss.frameworks = 'AVFAudio'
  end

  # `CallFocusFilter`, the app's Focus filter, and `FocusFilterStore`, which shares the Focus filter
  # state between the app and its extensions through an App Group. It doesn't depend on Core.
  s.subspec 'Focus' do |ss|
    ss.source_files = 'Sources/VoIPFocus/**/*.swift'
    ss.frameworks = 'AppIntents'
  end

  # `CallPreviewActivities`, which shows call previews as Live Activities, with their
  # `CallPreviewAttributes`, the Join intent and the default views.
  s.subspec 'LiveActivity' do |ss|
    ss.dependency 'IosVoipSDK/Core'
    ss.source_files = 'Sources/VoIPLiveActivity/**/*.swift'
    ss.frameworks = 'ActivityKit', 'AppIntents', 'SwiftUI', 'UIKit', 'WidgetKit'
  end

  # `LiveCommunicationKitAdapter`, which presents calls with LiveCommunicationKit.
  s.subspec 'LiveCommunicationKit' do |ss|
    ss.dependency 'IosVoipSDK/Core'
    ss.source_files = 'Sources/VoIPLiveCommunicationKit/**/*.swift'
    ss.frameworks = 'LiveCommunicationKit', 'AVFAudio'
  end

  # `PushKitSource`, with the Objective-C wrapper that completes each push once. It follows whether
  # the app is active from UIKit's notifications.
  s.subspec 'PushKit' do |ss|
    ss.dependency 'IosVoipSDK/Core'
    ss.source_files = ['Sources/VoIPPushKit/**/*.swift', 'Sources/VoIPPushDelivery/**/*.{h,m}']
    ss.public_header_files = 'Sources/VoIPPushDelivery/include/*.h'
    ss.frameworks = 'PushKit', 'UIKit'
  end

  # `CallNotifier`, which posts a communication notification for each call that a Focus filters,
  # with `UserNotificationsAdapter`.
  s.subspec 'Notifications' do |ss|
    ss.dependency 'IosVoipSDK/Core'
    ss.source_files = 'Sources/VoIPNotifications/**/*.swift'
    ss.frameworks = 'UserNotifications', 'Intents'
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
    ss.dependency 'IosVoipSDK/Notifications'
    ss.dependency 'IosVoipSDK/LiveActivity'
    ss.source_files = 'Sources/VoIPTesting/**/*.swift'
  end
end
