import type { Caller } from 'ios-voip-sdk';

export function callerFixture(): Caller {
  return {
    handleType: 'phone',
    value: '+15555550142',
    displayName: 'SDK example',
    hostContactID: 'sdk-example-caller',
  };
}
