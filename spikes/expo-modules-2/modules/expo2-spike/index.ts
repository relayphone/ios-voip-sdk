import { NativeModule, requireNativeModule } from 'expo';

declare class Expo2SpikeModule extends NativeModule {
  hello(): string;
}

export default requireNativeModule<Expo2SpikeModule>('Expo2Spike');
