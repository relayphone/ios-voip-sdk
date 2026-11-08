export type JourneyStage = 'incoming' | 'preview' | 'elsewhere' | 'server-event' | 'filtered' | 'passed' | 'failed';
export interface JourneyResults {
  schemaVersion: 1;
  runID: string;
  stage: JourneyStage;
  snapshots: { step: string; id: string; status: string; direction: string; previewReason?: string; filterCause?: string }[];
  handlers: { kind: 'start' | 'join'; id: string; origin: string }[];
  actions: { id: string; kind: string; origin: string }[];
  outcomes: { id: string; eventID: string; status: string; previewReason?: string; filterCause?: string }[];
  elsewhere: { conversationId: string; serverCallId: string; eventId: string }[];
  completed: string[];
  failure?: string;
}

export function journeyIDs(runID: string) {
  return { incoming: `${runID}-incoming`, outgoing: `${runID}-outgoing`, preview: `${runID}-preview`,
    elsewhere: `${runID}-elsewhere`, filtered: `${runID}-filtered` };
}
