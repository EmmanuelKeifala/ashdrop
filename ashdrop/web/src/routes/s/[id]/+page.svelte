<script lang="ts">
	import { onMount } from 'svelte';
	import { page } from '$app/state';
	import Mark from '$lib/components/Mark.svelte';
	import GithubIcon from '$lib/components/GithubIcon.svelte';
	import { parseEnv, maskValue, type EnvPair } from '$lib/env';
	import { decryptSecret } from '$lib/crypto';
	import { fetchSecret, burnSecret } from '$lib/api';

	type Phase = 'loading' | 'sealed' | 'burning' | 'revealing' | 'revealed' | 'gone' | 'nokey' | 'error';
	let phase = $state<Phase>('loading');
	let errMsg = $state('');

	const id = page.params.id ?? '';
	let keyB64 = '';
	let cipher: { ciphertext: string; iv: string } | null = null;

	let plaintext = $state('');
	let pairs = $state<EnvPair[]>([]);
	let revealed = $state(false); // unmask values
	let copied = $state(false);

	// burn-animation props (computed once)
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
		keyB64 = location.hash.slice(1);
		if (!keyB64) {
			phase = 'nokey';
			return;
		}
		try {
			const s = await fetchSecret(id);
			if (!s) {
				phase = 'gone';
				return;
			}
			cipher = { ciphertext: s.ciphertext, iv: s.iv };
			phase = 'sealed';
		} catch {
			phase = 'error';
			errMsg = 'Could not reach the server.';
		}
	});

	async function reveal() {
		if (!cipher) return;
		const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
		phase = reduce ? 'revealing' : 'burning';
		try {
			plaintext = await decryptSecret(cipher.ciphertext, cipher.iv, keyB64);
			pairs = parseEnv(plaintext);
			// burn after a successful decrypt — never before (wrong key / drop shouldn't destroy it)
			await burnSecret(id);
			if (!reduce) await sleep(1000); // let the ash settle
			phase = 'revealed';
		} catch {
			phase = 'error';
			errMsg = 'This link is invalid, was tampered with, or the key is wrong.';
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

<header class="nav">
	<a href="/" class="brand"><Mark specks={false} class="brand-mark" />ashdrop</a>
	<a href="https://github.com/abdullah4tech/ashdrop" target="_blank" rel="noreferrer" class="gh">
		<GithubIcon size="0.95rem" /> GitHub
	</a>
</header>

<main>
	{#if phase === 'loading'}
		<p class="muted">Looking for the drop…</p>
	{:else if phase === 'sealed'}
		<div class="card center">
			<Mark size="2.4rem" class="big-mark" />
			<h1>A secret was shared with you</h1>
			<p class="warn">Opening it destroys it. You get <strong>one</strong> look — copy what you need.</p>
			<button class="btn-burn" onclick={reveal}>Reveal secret 🔥</button>
		</div>
	{:else if phase === 'burning'}
		<div class="card center burn-stage">
			<div class="burn-lines">
				{#each burnLines as l, i (i)}
					<div class="burn-line" style="--d:{l.delay}ms">{l.text}</div>
				{/each}
			</div>
			<div class="embers" aria-hidden="true">
				{#each embers as e, i (i)}
					<span
						class="ember"
						style="left:{e.left}%; --delay:{e.delay}ms; --dur:{e.dur}ms; width:{e.size}px; height:{e.size}px"
					></span>
				{/each}
			</div>
			<p class="burn-label">decrypting &amp; burning…</p>
		</div>
	{:else if phase === 'revealing'}
		<p class="muted">Decrypting locally…</p>
	{:else if phase === 'revealed'}
		<div class="burned-banner">🔥 This link is now destroyed. It won’t open again — copy what you need below.</div>
		<div class="vars">
			<div class="vars-bar">
				<span>{pairs.length || 1} {pairs.length === 1 ? 'value' : 'values'}</span>
				<button class="ghost-sm" onclick={() => (revealed = !revealed)}>{revealed ? 'Hide' : 'Reveal'} values</button>
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
			<button class="btn-burn" onclick={copyAll}>{copied ? 'Copied ✓' : 'Copy all'}</button>
			<button class="btn-ghost" onclick={download}>Download .env</button>
		</div>

		<details class="cli">
			<summary>CLI one-liner</summary>
			<pre><code>export $(cat .env | xargs)</code></pre>
		</details>
	{:else if phase === 'gone'}
		<div class="card center">
			<h1>This secret no longer exists</h1>
			<p class="muted">It was already opened, or it expired. Secrets are one-time by design.</p>
			<a href="/" class="btn-burn linkbtn">Make your own →</a>
		</div>
	{:else if phase === 'nokey'}
		<div class="card center">
			<h1>This link is incomplete</h1>
			<p class="muted">The part after <code>#</code> — the decryption key — is missing, so this can’t be opened. Ask the sender for the full link.</p>
		</div>
	{:else}
		<div class="card center">
			<h1>Couldn’t open this</h1>
			<p class="muted">{errMsg}</p>
			<a href="/" class="btn-burn linkbtn">Make your own →</a>
		</div>
	{/if}
</main>

<style>
	.nav {
		display: flex;
		align-items: center;
		justify-content: space-between;
		max-width: 42rem;
		margin: 0 auto;
		padding: 1.5rem;
	}
	.brand {
		display: inline-flex;
		align-items: center;
		gap: 0.4rem;
		font-family: var(--font-mono);
		font-weight: 700;
		font-size: 1.05rem;
		color: var(--color-ink);
		text-decoration: none;
	}
	.brand :global(.brand-mark) {
		color: var(--color-rust);
	}
	.gh {
		display: inline-flex;
		align-items: center;
		gap: 0.4rem;
		font-size: 0.85rem;
		color: var(--color-rust);
		text-decoration: none;
	}
	.gh:hover {
		color: var(--color-rust-deep);
	}
	main {
		max-width: 42rem;
		margin: 0 auto;
		padding: 2rem 1.5rem 5rem;
	}
	.muted {
		color: var(--color-ash);
	}

	.card {
		border: 1px solid var(--color-ashline);
		border-radius: 14px;
		background: var(--color-paper);
		padding: 2.5rem 2rem;
	}
	.center {
		text-align: center;
	}
	.card :global(.big-mark) {
		color: var(--color-rust);
	}
	h1 {
		font-family: var(--font-display);
		font-size: clamp(1.5rem, 3.5vw, 2.1rem);
		font-weight: 700;
		letter-spacing: -0.02em;
		margin: 0.8rem 0 0.6rem;
	}
	.warn {
		color: var(--color-ash);
		margin: 0 0 1.6rem;
	}
	.warn strong {
		color: var(--color-rust);
	}
	code {
		font-family: var(--font-mono);
		color: var(--color-rust);
	}

	.btn-burn {
		padding: 0.85rem 1.6rem;
		border: 0;
		border-radius: 10px;
		background: var(--color-rust);
		color: var(--color-paper);
		font-weight: 600;
		font-size: 1rem;
		cursor: pointer;
		transition: background 0.2s, transform 0.18s;
		text-decoration: none;
		display: inline-block;
	}
	.btn-burn:hover {
		background: var(--color-rust-deep);
		transform: translateY(-2px);
	}
	.linkbtn {
		margin-top: 1.4rem;
	}

	/* burn animation */
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
		0% {
			opacity: 1;
			transform: translateY(0);
			filter: blur(0);
		}
		100% {
			opacity: 0;
			transform: translateY(-16px);
			filter: blur(4px);
		}
	}
	.embers {
		position: absolute;
		inset: 0;
		pointer-events: none;
	}
	.ember {
		position: absolute;
		bottom: 2.5rem;
		border-radius: 50%;
		background: var(--color-rust);
		box-shadow: 0 0 6px 1px color-mix(in oklab, var(--color-rust) 70%, transparent);
		opacity: 0;
		animation: ember-rise var(--dur) ease-out forwards;
		animation-delay: var(--delay);
	}
	@keyframes ember-rise {
		0% {
			opacity: 0;
			transform: translateY(0) scale(1);
		}
		25% {
			opacity: 0.9;
		}
		100% {
			opacity: 0;
			transform: translateY(-90px) scale(0.3);
		}
	}
	.burn-label {
		margin: 1.2rem 0 0;
		font-family: var(--font-mono);
		font-size: 0.78rem;
		color: var(--color-rust);
		text-align: center;
	}

	.burned-banner {
		border: 1px solid color-mix(in oklab, var(--color-rust) 35%, var(--color-ashline));
		background: color-mix(in oklab, var(--color-rust) 7%, var(--color-paper));
		color: var(--color-ink);
		border-radius: 10px;
		padding: 0.85rem 1.1rem;
		font-size: 0.9rem;
		margin-bottom: 1.4rem;
	}

	.vars {
		border: 1px solid var(--color-ashline);
		border-radius: 12px;
		background: var(--color-paper);
		overflow: hidden;
	}
	.vars-bar {
		display: flex;
		justify-content: space-between;
		align-items: center;
		padding: 0.7rem 1rem;
		border-bottom: 1px solid var(--color-ashline);
		font-family: var(--font-mono);
		font-size: 0.78rem;
		color: var(--color-ash);
	}
	.ghost-sm {
		border: 1px solid var(--color-ashline);
		background: transparent;
		border-radius: 7px;
		padding: 0.25rem 0.6rem;
		font-size: 0.74rem;
		color: var(--color-ink);
		cursor: pointer;
	}
	table {
		width: 100%;
		border-collapse: collapse;
		font-family: var(--font-mono);
		font-size: 0.84rem;
	}
	td {
		padding: 0.6rem 1rem;
		border-bottom: 1px solid var(--color-ashline);
		vertical-align: top;
	}
	tr:last-child td {
		border-bottom: 0;
	}
	.k {
		color: var(--color-rust);
		white-space: nowrap;
	}
	.v {
		color: var(--color-ink);
		word-break: break-all;
		width: 100%;
	}
	.raw {
		margin: 0;
		padding: 1rem;
		font-family: var(--font-mono);
		font-size: 0.84rem;
		white-space: pre-wrap;
		word-break: break-all;
	}

	.actions {
		display: flex;
		gap: 0.7rem;
		flex-wrap: wrap;
		margin: 1.3rem 0;
	}
	.btn-ghost {
		padding: 0.85rem 1.4rem;
		border: 1px solid var(--color-rust);
		border-radius: 10px;
		background: transparent;
		color: var(--color-rust);
		font-weight: 600;
		cursor: pointer;
	}
	.btn-ghost:hover {
		background: var(--color-rust);
		color: var(--color-paper);
	}

	.cli summary {
		cursor: pointer;
		font-size: 0.85rem;
		color: var(--color-ash);
	}
	.cli pre {
		margin: 0.6rem 0 0;
		padding: 0.8rem 1rem;
		background: var(--color-paper);
		border: 1px solid var(--color-ashline);
		border-radius: 8px;
		font-family: var(--font-mono);
		font-size: 0.82rem;
		overflow-x: auto;
	}
</style>
