/* Thin client for the Ashdrop API. The server only ever sees ciphertext. */

const BASE = import.meta.env.VITE_API_URL ?? 'http://localhost:8080';

interface CreateInputBase {
	ciphertext: string;
	iv: string;
	ttl: number; // seconds
	maxViews: number; // 0 = unlimited
}

export type CreateInput =
	| (CreateInputBase & { ephemeralPub: string; recipientPub: string })
	| (CreateInputBase & { ephemeralPub?: never; recipientPub?: never });

export interface CreateResult {
	id: string;
	notifyToken: string;
	expiresAt: number;
}

export interface FetchedSecret {
	ciphertext: string;
	iv: string;
	viewsLeft: number; // -1 = unlimited
	ephemeralPub: string;
	recipientKeyed: boolean;
}

export interface OpenedSecret {
	ciphertext: string;
	iv: string;
	ephemeralPub: string;
	recipientKeyed: boolean;
}

export interface DropMetadata {
	recipientKeyed: boolean;
	recipientPub: string;
	expiresAt: number;
	viewsLeft: number;
}

export async function createSecret(input: CreateInput): Promise<CreateResult> {
	const r = await fetch(`${BASE}/api/secrets`, {
		method: 'POST',
		headers: { 'content-type': 'application/json' },
		body: JSON.stringify(input)
	});
	if (r.status === 429) throw new Error('Too many drops — give it a minute.');
	if (!r.ok) throw new Error('Could not create the drop.');
	return r.json();
}

/** Returns null when the secret is gone (burned, expired, or never existed). */
export async function fetchSecret(id: string): Promise<FetchedSecret | null> {
	const r = await fetch(`${BASE}/api/secrets/${id}`);
	if (r.status === 404) return null;
	if (!r.ok) throw new Error('Could not load the drop.');
	return r.json();
}

export async function fetchMetadata(id: string): Promise<DropMetadata | null> {
	const r = await fetch(`${BASE}/api/secrets/${id}/metadata`);
	if (r.status === 404) return null;
	if (!r.ok) throw new Error('Could not load the drop.');
	return r.json();
}

export async function openSecret(id: string): Promise<OpenedSecret | null> {
	const r = await fetch(`${BASE}/api/secrets/${id}/open`, { method: 'POST' });
	if (r.status === 404) return null;
	if (!r.ok) throw new Error('Could not open the drop.');
	return r.json();
}

export async function burnSecret(id: string): Promise<void> {
	await fetch(`${BASE}/api/secrets/${id}/burn`, { method: 'POST' });
}

export interface Status {
	opened: boolean;
	openedAt: number | null;
}

export async function fetchStatus(id: string, notifyToken: string): Promise<Status | null> {
	const r = await fetch(
		`${BASE}/api/secrets/${id}/status?notifyToken=${encodeURIComponent(notifyToken)}`
	);
	if (!r.ok) return null;
	return r.json();
}
