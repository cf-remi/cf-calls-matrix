// MatrixRTC API — backed by Cloudflare RealtimeKit (RTK)
//
// Element Web / Element X initiate calls by:
// 1. Publishing m.call.member state events in the room
// 2. Calling GET /rtc/transports to discover the focus URL
// 3. Calling POST /livekit/get_token (or equivalent) to get a session token
//
// We advertise our homeserver's /rtk/join_call endpoint as the focus,
// then issue RTK participant tokens from there.

import { Hono } from 'hono';
import type { AppEnv } from '../types';
import { requireAuth } from '../middleware/auth';
import { getRtkConfig, getOrCreateMeeting, addParticipant, RtkMeetingExpiredError } from '../services/rtk';

const app = new Hono<AppEnv>();

// ---------------------------------------------------------------------------
// MSC4143: RTC transports discovery
// Tells Element Web which focus/SFU to use for calls.
// We point it at our own /rtk/get_token endpoint.
// ---------------------------------------------------------------------------
app.get('/_matrix/client/unstable/org.matrix.msc4143/rtc/transports', (c) => {
  const config = getRtkConfig(c.env);

  if (!config) {
    // RTK not configured — return empty so clients fall back to legacy 1:1 WebRTC
    return c.json({ transports: [] });
  }

  // Advertise our RTK token endpoint as a "livekit" focus.
  // Element Web / Element X treat any focus with type "livekit" as an SFU
  // and will call its get_token URL with an OpenID token to obtain a session token.
  return c.json({
    transports: [
      {
        type: 'livekit',
        livekit_service_url: `https://${c.env.SERVER_NAME}/rtk/get_token`,
      },
    ],
  });
});

// ---------------------------------------------------------------------------
// POST /rtk/get_token
// Called by Element Web / Element X with an OpenID token.
// We verify the OpenID token against our own homeserver, then issue an RTK
// participant token for that user in the requested room.
//
// Request body (Element X / MSC4195 style):
//   { room: "!id:server", device_id: "DEVICEID", openid_token: {...} }
// ---------------------------------------------------------------------------
app.post('/rtk/get_token', async (c) => {
  const config = getRtkConfig(c.env);
  if (!config) {
    return c.json({ errcode: 'M_UNKNOWN', error: 'Voice/video calls not configured on this server' }, 503);
  }

  let body: any;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ errcode: 'M_NOT_JSON', error: 'Invalid JSON' }, 400);
  }

  // Support both room_id (old) and room (Element X)
  const roomId: string | undefined = body.room ?? body.room_id;
  const openidToken = body.openid_token;
  // device_id can come as a string (Element X) or inside member object (old)
  const deviceId: string | undefined = body.device_id ?? body.member?.claimed_device_id;

  if (!roomId || !openidToken) {
    return c.json({ errcode: 'M_MISSING_PARAM', error: 'room and openid_token are required' }, 400);
  }

  // Verify the OpenID token by calling our own homeserver's userinfo endpoint
  // This confirms the caller is a legitimate user on this homeserver
  let userId: string;
  let verifiedDeviceId: string;
  try {
    const userinfoRes = await fetch(
      `https://${c.env.SERVER_NAME}/_matrix/federation/v1/openid/userinfo?access_token=${encodeURIComponent(openidToken.access_token)}`
    );
    if (!userinfoRes.ok) {
      return c.json({ errcode: 'M_FORBIDDEN', error: 'OpenID token verification failed' }, 403);
    }
    const userinfo = await userinfoRes.json() as any;
    userId = userinfo.sub;
    if (!userId) throw new Error('no sub in userinfo');
    // Use provided device_id if present, fallback to a hash of the access token
    verifiedDeviceId = deviceId || openidToken.access_token.slice(0, 16);
  } catch (e) {
    return c.json({ errcode: 'M_FORBIDDEN', error: 'Failed to verify OpenID token' }, 403);
  }

  // Verify the user is actually a member of the room
  const membership = await c.env.DB.prepare(
    `SELECT membership FROM room_memberships WHERE room_id = ? AND user_id = ?`
  ).bind(roomId, userId).first<{ membership: string }>();

  if (!membership || membership.membership !== 'join') {
    return c.json({ errcode: 'M_FORBIDDEN', error: 'User is not a member of this room' }, 403);
  }

  // Look up display name
  const profile = await c.env.DB.prepare(
    `SELECT display_name FROM users WHERE user_id = ?`
  ).bind(userId).first<{ display_name: string | null }>();
  const displayName = profile?.display_name || userId;

  // Get or create the RTK meeting for this Matrix room
  let meetingId: string;
  try {
    meetingId = await getOrCreateMeeting(config, roomId, c.env.CACHE);
  } catch (e) {
    console.error('[rtk] Failed to get/create meeting:', e);
    return c.json({ errcode: 'M_UNKNOWN', error: 'Failed to create call session' }, 502);
  }

  // Issue RTK participant token, with retry on expired meeting
  let rtkToken: string;
  try {
    rtkToken = await addParticipant(config, meetingId, userId, verifiedDeviceId, displayName);
  } catch (e) {
    if (e instanceof RtkMeetingExpiredError) {
      // Clear cache and create a fresh meeting
      await c.env.CACHE.delete(`rtk_meeting:${roomId}`);
      try {
        meetingId = await getOrCreateMeeting(config, roomId, c.env.CACHE);
        rtkToken = await addParticipant(config, meetingId, userId, verifiedDeviceId, displayName);
      } catch (e2) {
        console.error('[rtk] Retry failed:', e2);
        return c.json({ errcode: 'M_UNKNOWN', error: 'Failed to join call session' }, 502);
      }
    } else {
      console.error('[rtk] addParticipant failed:', e);
      return c.json({ errcode: 'M_UNKNOWN', error: 'Failed to join call session' }, 502);
    }
  }

  // Return in the format Element Web / Element X expects from a LiveKit focus:
  // { access_token: "<jwt>", url: "<rtk-sdk-url>" }
  // RTK tokens are used by the Dyte/RTK SDK, not raw LiveKit.
  // We return the token so the client can initialize the RTK SDK.
  return c.json({
    access_token: rtkToken,
    // The RTK SDK connects to Cloudflare's infrastructure automatically using this token
  });
});

// ---------------------------------------------------------------------------
// Legacy endpoint: POST /livekit/get_token
// Some versions of Element X use this path. Proxy to /rtk/get_token.
// ---------------------------------------------------------------------------
app.post('/livekit/get_token', async (c) => {
  // Re-use the same handler by forwarding internally
  const newReq = new Request(`https://${c.env.SERVER_NAME}/rtk/get_token`, {
    method: 'POST',
    headers: c.req.raw.headers,
    body: c.req.raw.body,
  });
  return app.fetch(newReq, c.env, c.executionCtx);
});

export default app;
