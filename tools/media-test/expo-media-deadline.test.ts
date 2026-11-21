import assert from 'node:assert/strict';
import { test } from 'node:test';
import { configureJourneyDeadline } from '../expo-journey-bundle.ts';

test('the media example configures the Answer preparation budget independently of the connection budget', () => {
  const commands: { file: string; args: readonly string[] }[] = [];
  const execute = (file: string, args: readonly string[]) => { commands.push({ file, args }); return ''; };
  const connection = {
    file: 'plutil',
    args: ['-replace', 'VoIPConversationsFulfillAnswerCallTimeout', '-integer', '27', '/example/ios/VoIPExample/Info.plist'],
  };
  configureJourneyDeadline('/example/ios', execute);
  assert.deepEqual(commands.splice(0), [connection]);
  configureJourneyDeadline('/example/ios', execute, true);
  assert.deepEqual(commands, [connection, {
    file: 'plutil',
    args: ['-replace', 'VoIPConversationsMediaPreparationTimeout', '-integer', '10', '/example/ios/VoIPExample/Info.plist'],
  }]);
});
