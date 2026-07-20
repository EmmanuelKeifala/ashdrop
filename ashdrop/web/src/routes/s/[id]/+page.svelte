<script lang="ts">
	import { onMount } from 'svelte';
	import { page } from '$app/state';
	import { parseEnv, maskValue, type EnvPair } from '$lib/env';
	import { decryptSecret, decryptWithMyKey, hasMyKeyPair, myPublicKeyB64 } from '$lib/crypto';
	import { fetchMetadata, fetchSecret, openSecret, burnSecret } from '$lib/api';

	type Phase = 'loading' | 'sealed' | 'recipient-sealed' | 'no-local-key' | 'burning' | 'revealing' | 'revealed' | 'gone' | 'nokey' | 'error';
	let phase = $state<Phase>('loading');
	let errMsg = $state('');

	const id = page.params.id ?? '';
	let keyB64 = '';
	let cipher: { ciphertext: string; iv: string; ephemeralPub: string; recipientKeyed: boolean } | null = null;
	let opensOnReveal = false;
	let expectedRecipientPub = '';
	let recipientKeyMismatch = $state(false);

	let plaintext = $state('');
	let pairs = $state<EnvPair[]>([]);
	let revealed = $state(false);
	let copied = $state(false);

	const CIPHER = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
	const rnd = (n: number) =>
		Array.from({ length: n }, () => CIPHER[(Math.random() * CIPHER.length) | 0]).join('');
	const burnLines = Array.from({ length: 5 }, (_, i) => ({ text: rnd(20 + (i % 3) * 7), delay: i * 90 }));
	const embers = Array.from({ length: 16 }, () => ({
		left: Math.round(Math.random() * 100),
		delay: Math.round(Math.random() * 500),
		dur: Math.round(700 + Math.random() * 600),
		size: Math.round(3 + Math.random() * 4)
	}));
	const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

	onMount(async () => {
		try {
			const metadata = await fetchMetadata(id);
			if (!metadata) { phase = 'gone'; return; }
			if (metadata.recipientKeyed && metadata.recipientPub) {
				const hasKeyPair = hasMyKeyPair();
				const matchesRecipient = myPublicKeyB64() === metadata.recipientPub;
				if (!matchesRecipient || !hasKeyPair) {
					recipientKeyMismatch = hasKeyPair && !matchesRecipient;
					phase = 'no-local-key';
					return;
				}
				expectedRecipientPub = metadata.recipientPub;
				opensOnReveal = true;
				phase = 'recipient-sealed';
				return;
			}

			const s = await fetchSecret(id);
			if (!s) { phase = 'gone'; return; }
			cipher = { ciphertext: s.ciphertext, iv: s.iv, ephemeralPub: s.ephemeralPub, recipientKeyed: s.recipientKeyed };
			if (s.recipientKeyed) {
				phase = hasMyKeyPair() ? 'recipient-sealed' : 'no-local-key';
			} else {
				keyB64 = location.hash.slice(1);
				phase = keyB64 ? 'sealed' : 'nokey';
			}
		} catch {
			phase = 'error';
			errMsg = 'Could not reach the server.';
		}
	});

	async function reveal() {
		const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
		phase = reduce ? 'revealing' : 'burning';
		let secret = cipher;
		try {
			if (opensOnReveal) {
				const hasKeyPair = hasMyKeyPair();
				const currentRecipientPub = myPublicKeyB64();
				if (!hasKeyPair || currentRecipientPub !== expectedRecipientPub) {
					recipientKeyMismatch = hasKeyPair && currentRecipientPub !== expectedRecipientPub;
					phase = 'no-local-key';
					return;
				}
				const opened = await openSecret(id);
				if (!opened) { phase = 'gone'; return; }
				secret = opened;
				cipher = opened;
			}
			if (!secret) return;

			if (secret.recipientKeyed) {
				plaintext = await decryptWithMyKey(secret.ciphertext, secret.iv, secret.ephemeralPub);
			} else {
				plaintext = await decryptSecret(secret.ciphertext, secret.iv, keyB64);
			}
			pairs = parseEnv(plaintext);
			if (!opensOnReveal) await burnSecret(id);
			if (!reduce) await sleep(1000);
			phase = 'revealed';
		} catch {
			phase = 'error';
			errMsg = secret?.recipientKeyed || opensOnReveal
				? 'Could not decrypt. Make sure you are on the same browser where you set up your receive address.'
				: 'This link is invalid or was tampered with.';
		}
	}

	async function copyAll() {
		await navigator.clipboard.writeText(plaintext);
		copied = true;
		setTimeout(() => (copied = false), 1800);
	}

	function download() {
		const blob = new Blob([plaintext], { type: 'text/plain' });
		const url = URL.createObjectURL(blob);
		const a = document.createElement('a');
		a.href = url;
		a.download = '.env';
		a.click();
		URL.revokeObjectURL(url);
	}
</script>

<svelte:head><title>Open a drop — Ashdrop</title></svelte:head>

<main>
	{#if phase === 'loading'}
		<p class="muted">Looking for the drop…</p>

	{:else if phase === 'recipient-sealed'}
		<div class="card">
			<p class="eyebrow">end-to-end encrypted · for you only</p>
			<h1>A secret was dropped for you.</h1>
			<p class="warn">Opening it destroys it. You get <strong>one</strong> look — copy what you need.</p>
			<button class="cta" onclick={reveal}>Reveal secret</button>
		</div>

	{:else if phase === 'no-local-key'}
		<div class="card">
			<h1>Wrong browser or device.</h1>
			{#if recipientKeyMismatch}
				<p class="muted">This drop targets a different local receive address. Open it on the browser where that address was set up.</p>
			{:else}
				<p class="muted">This drop was encrypted for a specific receive address. Open it on the browser where you set up your key.</p>
			{/if}
			<a href="/me" class="cta" style="display:inline-block;text-decoration:none;margin-top:1.4rem">Check your receive address →</a>
		</div>

	{:else if phase === 'sealed'}
		<div class="card">
			<p class="eyebrow">zero-knowledge · self-destructing</p>
			<h1>A secret was shared with you.</h1>
			<p class="warn">Opening it destroys it. You get <strong>one</strong> look — copy what you need.</p>
			<button class="cta" onclick={reveal}>Reveal secret</button>
		</div>

	{:else if phase === 'burning'}
		<div class="card burn-stage">
			<div class="burn-lines">
				{#each burnLines as l, i (i)}
					<div class="burn-line" style="--d:{l.delay}ms">{l.text}</div>
				{/each}
			</div>
			<div class="embers" aria-hidden="true">
				{#each embers as e, i (i)}
					<span class="ember" style="left:{e.left}%;--delay:{e.delay}ms;--dur:{e.dur}ms;width:{e.size}px;height:{e.size}px"></span>
				{/each}
			</div>
			<p class="burn-label">decrypting &amp; burning…</p>
		</div>

	{:else if phase === 'revealing'}
		<p class="muted">Decrypting locally…</p>

	{:else if phase === 'revealed'}
		<div class="burned-banner">This link is now destroyed. It won't open again.</div>

		<div class="vars">
			<div class="vars-bar">
				<span>{pairs.length || 1} {pairs.length === 1 ? 'value' : 'values'}</span>
				<button class="ghost-sm" onclick={() => (revealed = !revealed)}>{revealed ? 'Hide' : 'Show'} values</button>
			</div>
			{#if pairs.length}
				<table>
					<tbody>
						{#each pairs as p (p.key)}
							<tr>
								<td class="k">{p.key}</td>
								<td class="v">{revealed ? p.value : maskValue(p.value)}</td>
							</tr>
						{/each}
					</tbody>
				</table>
			{:else}
				<pre class="raw">{revealed ? plaintext : '••••••••••••'}</pre>
			{/if}
		</div>

		<div class="actions">
			<button class="cta-sm" onclick={copyAll}>{copied ? 'Copied' : 'Copy all'}</button>
			<button class="outline" onclick={download}>Download .env</button>
		</div>

		<details class="cli">
			<summary>CLI one-liner</summary>
			<pre><code>export $(cat .env | xargs)</code></pre>
		</details>

	{:else if phase === 'gone'}
		<div class="card">
			<h1>This secret no longer exists.</h1>
			<p class="muted">It was already opened, or it expired. Secrets are one-time by design.</p>
			<a href="/" class="cta" style="display:inline-block;text-decoration:none;margin-top:1.4rem">Make your own →</a>
		</div>

	{:else if phase === 'nokey'}
		<div class="card">
			<h1>This link is incomplete.</h1>
			<p class="muted">The decryption key (the part after <code>#</code>) is missing. Ask the sender for the full link.</p>
		</div>

	{:else}
		<div class="card">
			<h1>Couldn't open this.</h1>
			<p class="muted">{errMsg}</p>
			<a href="/" class="cta" style="display:inline-block;text-decoration:none;margin-top:1.4rem">Make your own →</a>
		</div>
	{/if}
</main>

<style>
	/* ── Layout ── */
	main {
		max-width: 42rem;
		margin: 0 auto;
		padding: 3.5rem 1.5rem 6rem;
	}
	.muted { color: var(--color-muted); font-size: 0.9rem; }

	/* ── Card states ── */
	.card {
		border: 1px solid var(--color-line);
		padding: 2.5rem 2rem;
		background: var(--color-surf);
	}
	.eyebrow {
		font-family: var(--font-mono);
		font-size: 0.68rem;
		letter-spacing: 0.1em;
		text-transform: uppercase;
		color: var(--color-muted);
		margin: 0 0 1rem;
	}
	h1 {
		font-family: var(--font-display);
		font-size: clamp(1.6rem, 4vw, 2.2rem);
		font-weight: 800;
		letter-spacing: -0.03em;
		margin: 0 0 0.7rem;
		line-height: 1.1;
	}
	.warn {
		color: var(--color-muted);
		margin: 0 0 1.6rem;
		font-size: 0.92rem;
		line-height: 1.55;
	}
	.warn strong { color: var(--color-ink); }
	code { font-family: var(--font-mono); font-size: 0.9em; }

	.cta {
		display: block;
		width: 100%;
		padding: 0.9rem 1.2rem;
		border: 0;
		background: var(--color-ink);
		color: var(--color-bg);
		font-family: var(--font-display);
		font-weight: 700;
		font-size: 0.95rem;
		letter-spacing: -0.01em;
		cursor: pointer;
		transition: background 0.12s;
		text-align: left;
	}
	.cta:hover { background: var(--color-rust); }

	/* ── Burn animation ── */
	.burn-stage {
		position: relative;
		overflow: hidden;
		min-height: 13rem;
		display: flex;
		flex-direction: column;
		justify-content: center;
	}
	.burn-lines {
		display: flex;
		flex-direction: column;
		gap: 0.5rem;
		align-items: center;
	}
	.burn-line {
		font-family: var(--font-mono);
		font-size: 0.84rem;
		color: var(--color-rust);
		max-width: 90%;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		animation: ash-line 0.85s ease forwards;
		animation-delay: var(--d);
	}
	@keyframes ash-line {
		0% { opacity: 1; transform: translateY(0); filter: blur(0); }
		100% { opacity: 0; transform: translateY(-16px); filter: blur(4px); }
	}
	.embers {
		position: absolute;
		inset: 0;
		pointer-events: none;
	}
	.ember {
		position: absolute;
		bottom: 2.5rem;
		background: var(--color-rust);
		opacity: 0;
		animation: ember-rise var(--dur) ease-out forwards;
		animation-delay: var(--delay);
	}
	@keyframes ember-rise {
		0% { opacity: 0; transform: translateY(0) scale(1); }
		25% { opacity: 0.9; }
		100% { opacity: 0; transform: translateY(-90px) scale(0.3); }
	}
	.burn-label {
		margin: 1.2rem 0 0;
		font-family: var(--font-mono);
		font-size: 0.75rem;
		color: var(--color-rust);
		text-align: center;
	}

	/* ── Revealed state ── */
	.burned-banner {
		border: 1px solid var(--color-line);
		border-left: 3px solid var(--color-rust);
		background: var(--color-surf);
		padding: 0.8rem 1rem;
		font-family: var(--font-mono);
		font-size: 0.8rem;
		color: var(--color-muted);
		margin-bottom: 1.4rem;
	}

	.vars {
		border: 1px solid var(--color-line);
		background: var(--color-bg);
		margin-bottom: 1.2rem;
	}
	.vars-bar {
		display: flex;
		justify-content: space-between;
		align-items: center;
		padding: 0.6rem 1rem;
		border-bottom: 1px solid var(--color-line);
		font-family: var(--font-mono);
		font-size: 0.75rem;
		color: var(--color-muted);
	}
	.ghost-sm {
		border: 1px solid var(--color-line);
		background: transparent;
		padding: 0.2rem 0.55rem;
		font-size: 0.72rem;
		font-family: var(--font-mono);
		color: var(--color-muted);
		cursor: pointer;
		transition: color 0.1s;
	}
	.ghost-sm:hover { color: var(--color-ink); }
	table { width: 100%; border-collapse: collapse; font-family: var(--font-mono); font-size: 0.82rem; }
	td { padding: 0.55rem 1rem; border-bottom: 1px solid var(--color-line); vertical-align: top; }
	tr:last-child td { border-bottom: 0; }
	.k { color: var(--color-rust); white-space: nowrap; }
	.v { color: var(--color-ink); word-break: break-all; width: 100%; }
	.raw {
		margin: 0;
		padding: 1rem;
		font-family: var(--font-mono);
		font-size: 0.82rem;
		white-space: pre-wrap;
		word-break: break-all;
		color: var(--color-ink);
	}

	.actions { display: flex; gap: 0.6rem; flex-wrap: wrap; margin-bottom: 1.2rem; }
	.cta-sm {
		padding: 0.75rem 1.3rem;
		border: 0;
		background: var(--color-ink);
		color: var(--color-bg);
		font-family: var(--font-mono);
		font-size: 0.82rem;
		font-weight: 600;
		cursor: pointer;
		transition: background 0.12s;
	}
	.cta-sm:hover { background: var(--color-rust); }
	.outline {
		padding: 0.75rem 1.3rem;
		border: 1px solid var(--color-line);
		background: transparent;
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: 0.82rem;
		cursor: pointer;
		transition: color 0.1s, border-color 0.1s;
	}
	.outline:hover { color: var(--color-ink); border-color: var(--color-ink); }

	.cli summary { cursor: pointer; font-size: 0.82rem; color: var(--color-muted); font-family: var(--font-mono); }
	.cli pre {
		margin: 0.5rem 0 0;
		padding: 0.75rem 1rem;
		background: var(--color-surf);
		border: 1px solid var(--color-line);
		font-family: var(--font-mono);
		font-size: 0.8rem;
		overflow-x: auto;
	}
</style>
