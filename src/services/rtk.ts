// Cloudflare RealtimeKit (RTK) service for MatrixRTC voice/video
// Creates RTK meetings and participant tokens to serve as a MatrixRTC focus

import type { Env } from '../types';

export interface RtkConfig {
  accountId: string;
  apiToken: string;
  appId: string;
  presetName: string;
}

export function getRtkConfig(env: Env): RtkConfig | null {
  if (!env.CF_ACCOUNT_ID || !env.CF_API_TOKEN || !env.CF_APP_ID) {
    return null;
  }
  return {
    accountId: env.CF_ACCOUNT_ID,
    apiToken: env.CF_API_TOKEN,
    appId: env.CF_APP_ID,
    presetName: env.RTK_PRESET_NAME || 'group_call_host',
  };
}

function rtkBase(config: RtkConfig): string {
  return `https://api.cloudflare.com/client/v4/accounts/${config.accountId}/realtime/kit/${config.appId}`;
}

function rtkHeaders(config: RtkConfig): Record<string, string> {
  return {
    'Content-Type': 'application/json',
    'Authorization': `Bearer ${config.apiToken}`,
  };
}

/**
 * Get or create an RTK meeting for a Matrix room.
 * The meeting title encodes the Matrix room ID so it's stable across restarts.
 */
export async function getOrCreateMeeting(
  config: RtkConfig,
  matrixRoomId: string,
  cache: KVNamespace
): Promise<string> {
  const cacheKey = `rtk_meeting:${matrixRoomId}`;

  // Check cache first
  const cached = await cache.get(cacheKey);
  if (cached) {
    // Verify the meeting still exists
    const checkRes = await fetch(`${rtkBase(config)}/meetings/${cached}`, {
      headers: rtkHeaders(config),
    });
    if (checkRes.ok) return cached;
    // Meeting expired — fall through to create a new one
    await cache.delete(cacheKey);
  }

  // Create a new meeting
  const res = await fetch(`${rtkBase(config)}/meetings`, {
    method: 'POST',
    headers: rtkHeaders(config),
    body: JSON.stringify({ title: `matrix-${matrixRoomId}` }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`RTK create meeting failed ${res.status}: ${body}`);
  }

  const data = await res.json() as any;
  const meetingId: string = data?.result?.id ?? data?.data?.id;
  if (!meetingId) throw new Error('RTK create meeting returned no ID');

  // Cache for 23 hours (RTK meetings last 24h by default)
  await cache.put(cacheKey, meetingId, { expirationTtl: 23 * 3600 });

  return meetingId;
}

/**
 * Add a participant to an RTK meeting and return their auth token.
 */
export async function addParticipant(
  config: RtkConfig,
  meetingId: string,
  userId: string,    // Matrix user ID e.g. @alice:example.com
  deviceId: string,  // Matrix device ID — makes identity unique per device
  displayName?: string
): Promise<string> {
  // RTK participant ID must be unique per user+device combo
  const participantId = `${userId}:${deviceId}`.replace(/[^a-zA-Z0-9_\-:.@]/g, '_');

  const res = await fetch(`${rtkBase(config)}/meetings/${meetingId}/participants`, {
    method: 'POST',
    headers: rtkHeaders(config),
    body: JSON.stringify({
      name: displayName || userId,
      preset_name: config.presetName,
      custom_participant_id: participantId,
    }),
  });

  if (!res.ok) {
    // If meeting expired, signal caller to retry with a new meeting
    if (res.status === 404) {
      throw new RtkMeetingExpiredError(meetingId);
    }
    const body = await res.text();
    throw new Error(`RTK add participant failed ${res.status}: ${body}`);
  }

  const data = await res.json() as any;
  const token: string = data?.result?.token ?? data?.data?.token;
  if (!token) throw new Error('RTK add participant returned no token');

  return token;
}

export class RtkMeetingExpiredError extends Error {
  constructor(public meetingId: string) {
    super(`RTK meeting ${meetingId} expired`);
    this.name = 'RtkMeetingExpiredError';
  }
}
