// Pairwise rendezvous: the only server-side piece of the app.
//
// It does deliberately little — peers who share a room code connect here over
// WebSocket, learn whether the other side is online, and relay small signaling
// JSON (invites, accept/decline, call state, UDP hole-punch candidates,
// annotation strokes). All media stays peer-to-peer UDP and never touches
// this worker.
//
// One Durable Object instance per room code, using WebSocket hibernation so
// an idle pair of connected apps costs ~nothing.

import { DurableObject } from "cloudflare:workers";

export interface Env {
  ROOMS: DurableObjectNamespace;
}

const CODE_PATTERN = /^\/room\/([a-z0-9][a-z0-9-]{2,62}[a-z0-9])$/;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/") {
      return new Response("pairwise rendezvous", { status: 200 });
    }
    const match = CODE_PATTERN.exec(url.pathname.toLowerCase());
    if (!match) {
      return new Response("not found", { status: 404 });
    }
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const room = env.ROOMS.get(env.ROOMS.idFromName(match[1]));
    return room.fetch(request);
  },
};

interface Attachment {
  id: string;
  name: string;
}

export class Room extends DurableObject {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const name = (url.searchParams.get("name") ?? "peer").slice(0, 64);
    const id = (url.searchParams.get("id") ?? crypto.randomUUID()).slice(0, 64);

    // A reconnect replaces any stale socket left by the same client (e.g.
    // after an unclean network drop the old socket lingers until timeout).
    for (const ws of this.ctx.getWebSockets()) {
      const att = ws.deserializeAttachment() as Attachment | null;
      if (att?.id === id) {
        ws.close(1000, "replaced by newer connection");
      }
    }
    const others = this.peers().filter((p) => p.att.id !== id);
    if (others.length >= 2) {
      return new Response("room full", { status: 409 });
    }

    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1]);
    pair[1].serializeAttachment({ id, name } satisfies Attachment);

    // App-level keepalive that never wakes the hibernated object.
    this.ctx.setWebSocketAutoResponse(
      new WebSocketRequestResponsePair('{"type":"ping"}', '{"type":"pong"}'),
    );

    pair[1].send(
      JSON.stringify({
        type: "peers",
        peers: others.map((p) => ({ id: p.att.id, name: p.att.name })),
      }),
    );
    for (const p of others) {
      p.ws.send(JSON.stringify({ type: "joined", id, name }));
    }

    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer) {
    if (typeof message !== "string" || message.length > 256 * 1024) return;
    let parsed: { type?: string; payload?: unknown };
    try {
      parsed = JSON.parse(message);
    } catch {
      return;
    }
    if (parsed.type !== "signal" || parsed.payload === undefined) return;
    const from = ws.deserializeAttachment() as Attachment | null;
    const out = JSON.stringify({
      type: "signal",
      from: { id: from?.id ?? "?", name: from?.name ?? "peer" },
      payload: parsed.payload,
    });
    for (const p of this.peers()) {
      if (p.ws !== ws) p.ws.send(out);
    }
  }

  async webSocketClose(ws: WebSocket) {
    this.announceLeft(ws);
  }

  async webSocketError(ws: WebSocket) {
    this.announceLeft(ws);
  }

  private announceLeft(ws: WebSocket) {
    const att = ws.deserializeAttachment() as Attachment | null;
    if (!att) return;
    // If the same client id still has another (replacement) socket, this was
    // just a reconnect — don't tell the peer they left.
    const remaining = this.peers().filter((p) => p.ws !== ws);
    if (remaining.some((p) => p.att.id === att.id)) return;
    const out = JSON.stringify({ type: "left", id: att.id, name: att.name });
    for (const p of remaining) {
      p.ws.send(out);
    }
  }

  private peers(): { ws: WebSocket; att: Attachment }[] {
    return this.ctx
      .getWebSockets()
      .map((ws) => ({ ws, att: ws.deserializeAttachment() as Attachment | null }))
      .filter((p): p is { ws: WebSocket; att: Attachment } => p.att !== null);
  }
}
