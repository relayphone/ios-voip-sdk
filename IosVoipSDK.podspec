require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))
runtime_version = File.read(File.join(__dir__, 'VERSION')).strip

Pod::Spec.new do |s|
  s.name = 'IosVoipSDK'
  s.version = package['version']
  s.summary = package['description']
  s.homepage = 'https://github.com/ziahamza/ios-voip-sdk'
  s.author = { 'Hamza Zia' => 'https://github.com/ziahamza' }
  s.license = { :type => 'UNLICENSED' }
  s.source = { :git => package['repository']['url'], :tag => "v#{s.version}" }
  s.platform = :ios, '17.4'
  s.swift_version = '6.0'
  s.static_framework = true
  s.dependency 'ExpoModulesCore'
  s.frameworks = 'LiveCommunicationKit', 'CallKit', 'AVFoundation', 'PushKit'
  s.source_files = 'Sources/**/*.{swift,h,m}', 'Expo/apple/**/*.swift'
  # The external DYLD loader is not part of the embedded SDK.
  s.exclude_files = 'Sources/Interposition/CKLoader.m'
  s.public_header_files = 'Sources/Interposition/**/CKRuntimeSeam.h', 'Sources/VoIPPlatform/include/*.h'
  s.resource_bundles = {
    'IosVoipSDKRuntime' => ['Sources/Engine/Resources/**/*.json', 'profiles/*.json']
  }
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'GCC_PREPROCESSOR_DEFINITIONS' => "$(inherited) CKSIM_SDK_SOURCE=1 CKSIM_RUNTIME_VERSION=\\\"#{runtime_version}\\\""
  }
end
