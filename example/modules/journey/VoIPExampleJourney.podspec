Pod::Spec.new do |s|
  s.name = 'VoIPExampleJourney'
  s.version = '0.0.0'
  s.summary = 'The example app calling journey; excluded from the SDK package.'
  s.homepage = 'https://github.com/ziahamza/ios-voip-sdk'
  s.author = 'Hamza Zia'
  s.license = { :type => 'UNLICENSED' }
  s.source = { :git => 'https://github.com/ziahamza/ios-voip-sdk.git' }
  s.platform = :ios, '17.4'
  s.swift_version = '6.0'
  s.static_framework = true
  s.dependency 'ExpoModulesCore'
  s.dependency 'IosVoipSDK'
  s.source_files = 'apple/*.{swift,h}'
  s.public_header_files = 'apple/VoIPExampleRuntimeControl.h'
  s.frameworks = 'LiveCommunicationKit', 'AVFoundation'
end
