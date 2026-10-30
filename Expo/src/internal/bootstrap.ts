import { requireNativeModule, type NativeModule } from 'expo';

/** @internal Example infrastructure; not part of RFC 0001's API. */
export interface BootstrapInfo {
  platform: 'ios';
  simulator: boolean;
  runtimeActive: boolean;
}

type BootstrapModule = NativeModule & {
  bootstrap(): Promise<BootstrapInfo>;
};

/** @internal Activates native simulator support before the example uses LCK. */
export function bootstrap(): Promise<BootstrapInfo> {
  // Resolve lazily so the example can show native module loading errors.
  return requireNativeModule<BootstrapModule>('IosVoipSDK').bootstrap();
}
