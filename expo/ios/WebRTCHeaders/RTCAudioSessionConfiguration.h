/*
 *  Declarations copied from WebRTC's sdk/objc/components/audio/RTCAudioSessionConfiguration.h.
 *
 *  Copyright 2016 The WebRTC Project Authors. All rights reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

// Only the subset ios-voip-sdk calls. The implementation comes from whichever
// WebRTC framework the app links; see README.md in this directory.

#pragma once

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol VoIPRTCAudioSessionConfiguration <NSObject>

@property(nonatomic, strong) NSString *category;
@property(nonatomic, assign) AVAudioSessionCategoryOptions categoryOptions;
@property(nonatomic, strong) NSString *mode;

@end

@protocol VoIPRTCAudioSessionConfigurationClass <NSObject>
+ (void)setWebRTCConfiguration:(id<VoIPRTCAudioSessionConfiguration>)configuration;
@end

static inline id<VoIPRTCAudioSessionConfiguration>
VoIPRTCAudioSessionConfigurationCreate(Class type) {
  return [[type alloc] init];
}

static inline void VoIPRTCAudioSessionConfigurationSetWebRTC(
    Class type, id<VoIPRTCAudioSessionConfiguration> configuration) {
  [(Class<VoIPRTCAudioSessionConfigurationClass>)type setWebRTCConfiguration:configuration];
}

NS_ASSUME_NONNULL_END
