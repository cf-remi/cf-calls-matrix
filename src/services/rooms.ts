// Room service helpers — shared logic used by route handlers and server-initiated operations

import type { Env } from '../types/env';
import type { PDU, RoomMemberContent } from '../types/matrix';
import {
  getRoom,
  getStateEvent,
  getRoomEvents,
  getMembership,
  storeEvent,
  updateMembership,
  notifyUsersOfEvent,
  getRoomByAlias,
} from './database';
import { generateEventId } from '../utils/ids';

/**
 * Join a user to a local room, bypassing join-rules checks.
 * Intended for server-initiated joins (e.g. auto-join on registration).
 * Silently succeeds if the user is already joined.
 *
 * @returns the room ID on success, null if the room doesn't exist
 */
export async function joinUserToRoom(
  db: D1Database,
  env: Env,
  roomIdOrAlias: string,
  userId: string,
): Promise<string | null> {
  // Resolve alias to room ID if needed
  let roomId: string;
  if (roomIdOrAlias.startsWith('#')) {
    const resolved = await getRoomByAlias(db, roomIdOrAlias);
    if (!resolved) {
      console.warn(`[auto-join] Alias not found: ${roomIdOrAlias}`);
      return null;
    }
    roomId = resolved;
  } else {
    roomId = roomIdOrAlias;
  }

  // Verify the room exists
  const room = await getRoom(db, roomId);
  if (!room) {
    console.warn(`[auto-join] Room not found: ${roomId}`);
    return null;
  }

  // Already joined — no-op
  const currentMembership = await getMembership(db, roomId, userId);
  if (currentMembership?.membership === 'join') {
    return roomId;
  }

  // Build auth events
  const createEvent = await getStateEvent(db, roomId, 'm.room.create');
  const joinRulesEvent = await getStateEvent(db, roomId, 'm.room.join_rules');
  const powerLevelsEvent = await getStateEvent(db, roomId, 'm.room.power_levels');

  const authEvents: string[] = [];
  if (createEvent) authEvents.push(createEvent.event_id);
  if (joinRulesEvent) authEvents.push(joinRulesEvent.event_id);
  if (powerLevelsEvent) authEvents.push(powerLevelsEvent.event_id);
  if (currentMembership) authEvents.push(currentMembership.eventId);

  // Build prev events
  const { events: latestEvents } = await getRoomEvents(db, roomId, undefined, 1);
  const prevEvents = latestEvents.map(e => e.event_id);

  const eventId = await generateEventId(env.SERVER_NAME);

  const memberContent: RoomMemberContent = { membership: 'join' };

  const event: PDU = {
    event_id: eventId,
    room_id: roomId,
    sender: userId,
    type: 'm.room.member',
    state_key: userId,
    content: memberContent,
    origin_server_ts: Date.now(),
    depth: (latestEvents[0]?.depth ?? 0) + 1,
    auth_events: authEvents,
    prev_events: prevEvents,
  };

  await storeEvent(db, event);
  await updateMembership(db, roomId, userId, 'join', eventId);
  await notifyUsersOfEvent(env, roomId, eventId, 'm.room.member');

  console.log(`[auto-join] Joined ${userId} to ${roomId}`);
  return roomId;
}
