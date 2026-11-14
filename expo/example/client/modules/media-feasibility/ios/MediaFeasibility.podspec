Pod::Spec.new do |s|
  s.name = 'MediaFeasibility'
  s.version = '1.0.0'
  s.summary = 'Native media example and simulator feasibility check.'
  s.homepage = 'https://github.com/relayphone/ios-voip-sdk'
  s.author = 'RelayPhone'
  s.license = { :type => 'UNLICENSED' }
  s.source = { :git => 'https://github.com/relayphone/ios-voip-sdk' }
  s.platform = :ios, '26.0'
  s.swift_version = '6.0'
  s.static_framework = true
  s.source_files = '*.swift'
  s.dependency 'ExpoModulesCore'
  s.dependency 'VoIPConversations/Module'
  s.dependency 'VoIPConversations/MediaTesting'
end
